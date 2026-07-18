# payments/tests.py
"""
Real test coverage for the payments app.

KEY TESTING PRINCIPLE — mocking the third-party boundary:
This app talks to Stripe over the network (creating checkout sessions,
verifying webhook signatures). We NEVER let tests call the real Stripe
API — that would be slow, require real API keys, and fail with no
internet (like in a CI pipeline). Instead we mock exactly at the
boundary between OUR code and Stripe's SDK:
  - `stripe.checkout.Session.create` — mocked to return a fake session
  - `stripe.Webhook.construct_event` — mocked to either return a fake
    parsed event, or raise the same exceptions Stripe's SDK would raise
    for a bad signature/payload.

This tests "does our code do the right thing given what Stripe could
plausibly send us" — not "does Stripe's API work" (that's Stripe's
job to test, not ours). This is exactly how you'd explain testing
third-party integrations in an interview.
"""

import json
from decimal import Decimal
from unittest.mock import patch, MagicMock

from django.test import TestCase, Client
from django.contrib.auth import get_user_model

import stripe

from orders.models import Order, Payment

User = get_user_model()


def make_user(email):
    return User.objects.create_user(email=email, password="StrongPass!2024", name="Test", is_active=True)


class CreateCheckoutSessionTests(TestCase):
    """Contract: checkout session creation validates input, checks the
    order exists, and — on success — stores the Stripe session id on
    the order for later webhook matching."""

    def setUp(self):
        self.client = Client()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.order = Order.objects.create(buyer=self.buyer, seller=self.seller, total_price=Decimal("500.00"))
        self.url = "/api/v1/payments/create-checkout-session/"

    def test_get_request_is_rejected(self):
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, 400)

    def test_missing_order_id_or_amount_is_rejected(self):
        response = self.client.post(
            self.url, data=json.dumps({"amount": 50000}), content_type="application/json"
        )
        self.assertEqual(response.status_code, 400)

    def test_nonexistent_order_returns_404(self):
        response = self.client.post(
            self.url,
            data=json.dumps({"order_id": 99999, "amount": 50000}),
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 404)

    @patch("payments.views.stripe.checkout.Session.create")
    def test_valid_request_creates_session_and_stores_id_on_order(self, mock_create):
        # Fake Stripe response — this is what stripe.checkout.Session.create()
        # would return on success. We don't test Stripe's behavior, only ours.
        mock_create.return_value = MagicMock(id="cs_test_fake123", url="https://checkout.stripe.com/fake123")

        response = self.client.post(
            self.url,
            data=json.dumps({"order_id": self.order.id, "amount": 50000, "product_name": "Test Order"}),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 200)
        body = json.loads(response.content)
        self.assertEqual(body["session_id"], "cs_test_fake123")

        self.order.refresh_from_db()
        self.assertEqual(self.order.stripe_session_id, "cs_test_fake123")

        # Confirm OUR code called Stripe with the right amount/currency —
        # this is the actual contract we own, not Stripe's response itself.
        _, kwargs = mock_create.call_args
        self.assertEqual(kwargs["line_items"][0]["price_data"]["unit_amount"], 50000)
        self.assertEqual(kwargs["client_reference_id"], str(self.order.id))


class StripeWebhookTests(TestCase):
    """Contract: the webhook only trusts events that pass Stripe's
    signature verification, and correctly updates the matching order
    on a successful checkout — without crashing on an unmatched or
    tampered event."""

    def setUp(self):
        self.client = Client()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.order = Order.objects.create(
            buyer=self.buyer, seller=self.seller, total_price=Decimal("500.00"),
            stripe_session_id="cs_test_realistic123",
        )
        self.url = "/api/v1/webhook/"

    def _post_with_fake_signature(self, body: bytes):
        return self.client.post(
            self.url, data=body, content_type="application/json", HTTP_STRIPE_SIGNATURE="fake_sig"
        )

    @patch("payments.webhooks.stripe.Webhook.construct_event")
    def test_invalid_signature_is_rejected(self, mock_construct):
        mock_construct.side_effect = stripe.SignatureVerificationError("bad sig", "fake_sig")

        response = self._post_with_fake_signature(b"{}")
        self.assertEqual(response.status_code, 400)

        self.order.refresh_from_db()
        self.assertNotEqual(self.order.status, Order.STATUS_PAID)  # untouched

    @patch("payments.webhooks.stripe.Webhook.construct_event")
    def test_malformed_payload_is_rejected(self, mock_construct):
        mock_construct.side_effect = ValueError("invalid JSON")

        response = self._post_with_fake_signature(b"not-json")
        self.assertEqual(response.status_code, 400)

    @patch("payments.webhooks.stripe.Webhook.construct_event")
    def test_completed_checkout_for_unknown_session_returns_404(self, mock_construct):
        mock_construct.return_value = {
            "type": "checkout.session.completed",
            "data": {"object": {"id": "cs_test_does_not_exist", "payment_intent": "pi_fake"}},
        }

        response = self._post_with_fake_signature(b"{}")
        self.assertEqual(response.status_code, 404)

    @patch("payments.webhooks.stripe.Webhook.construct_event")
    def test_completed_checkout_marks_matching_order_paid(self, mock_construct):
        mock_construct.return_value = {
            "type": "checkout.session.completed",
            "data": {"object": {"id": "cs_test_realistic123", "payment_intent": "pi_fake_999"}},
        }

        response = self._post_with_fake_signature(b"{}")
        self.assertEqual(response.status_code, 200)

        self.order.refresh_from_db()
        self.assertEqual(self.order.status, Order.STATUS_PAID)
        self.assertEqual(self.order.payment_status, Order.PAYMENT_SUCCESS)
        self.assertTrue(self.order.paid)
        self.assertEqual(self.order.payment_id, "pi_fake_999")
        self.assertEqual(self.order.amount_paid, self.order.total_price)

        payment = Payment.objects.get(order=self.order)
        self.assertEqual(payment.status, Order.PAYMENT_SUCCESS)
        self.assertEqual(payment.provider_payment_id, "pi_fake_999")

    @patch("payments.webhooks.stripe.Webhook.construct_event")
    def test_irrelevant_event_type_is_ignored_safely(self, mock_construct):
        """Contract: an event type we don't handle should return 200
        (acknowledge receipt to Stripe) without touching any order."""
        mock_construct.return_value = {
            "type": "payment_intent.created",
            "data": {"object": {"id": "pi_unrelated"}},
        }

        response = self._post_with_fake_signature(b"{}")
        self.assertEqual(response.status_code, 200)

        self.order.refresh_from_db()
        self.assertNotEqual(self.order.status, Order.STATUS_PAID)