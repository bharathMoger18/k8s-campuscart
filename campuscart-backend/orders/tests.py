# orders/tests.py
"""
Real test coverage for the orders app — the most business-critical app
in the system, since it ties together users, products, and payments.

Business rules under test (read directly from models.py / views.py):

1. STATE MACHINE: an order can only move through valid status transitions
   (PENDING -> PAID -> SHIPPED -> DELIVERED -> COMPLETED, or -> CANCELLED
   from early states). Invalid jumps must be rejected, not silently allowed.
2. PRIVACY: a user only ever sees orders where they are the buyer or seller
   — never someone else's order, not even by guessing an ID.
3. CART -> ORDER: converting a cart into order(s) must group items by
   seller, reject if the cart is empty, and reject if any product in the
   cart is no longer available.
4. ROLE-GATED ACTIONS: only the seller can update status; only the buyer
   can cancel or confirm delivery; wrong-role attempts are blocked, not
   silently allowed or crashing.
5. REFUNDS: a buyer can request a refund only for paid/shipped/delivered
   orders, never twice for the same order; only the seller/admin can
   approve or reject; approval flips the order to CANCELLED + REFUNDED.
"""

from decimal import Decimal
from django.test import TestCase
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient
from rest_framework import status

from .models import Order, OrderItem, Payment, RefundRequest
from products.models import Product
from cart.models import Cart, CartItem

User = get_user_model()


def make_user(email):
    return User.objects.create_user(email=email, password="StrongPass!2024", name="Test", is_active=True)


def make_product(owner, title="Item", price="100.00"):
    return Product.objects.create(owner=owner, title=title, category="Other", price=Decimal(price))


# ---------------------------------------------------------------------
# 1. STATE MACHINE (model-level — no HTTP needed, fast and precise)
# ---------------------------------------------------------------------
class OrderStateMachineTests(TestCase):
    """Contract: Order.set_status only allows moves defined in
    VALID_TRANSITIONS, and every change is recorded in history."""

    def setUp(self):
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.order = Order.objects.create(buyer=self.buyer, seller=self.seller, total_price=Decimal("500.00"))

    def test_valid_transition_pending_to_paid_succeeds(self):
        self.order.set_status(Order.STATUS_PAID, actor=self.seller, note="Paid")
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, Order.STATUS_PAID)
        self.assertEqual(self.order.status_history.count(), 1)

    def test_invalid_transition_pending_to_delivered_is_rejected(self):
        with self.assertRaises(ValueError):
            self.order.set_status(Order.STATUS_DELIVERED)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, Order.STATUS_PENDING)  # unchanged

    def test_terminal_status_completed_allows_no_further_transitions(self):
        self.order.status = Order.STATUS_COMPLETED
        self.order.save(update_fields=["status"])
        self.assertFalse(self.order.can_transition_to(Order.STATUS_SHIPPED))
        self.assertFalse(self.order.can_transition_to(Order.STATUS_CANCELLED))

    def test_mark_refunded_sets_cancelled_and_payment_refunded(self):
        self.order.status = Order.STATUS_PAID
        self.order.save(update_fields=["status"])

        self.order.mark_refunded(actor=self.seller, note="Refund approved")
        self.order.refresh_from_db()

        self.assertEqual(self.order.status, Order.STATUS_CANCELLED)
        self.assertEqual(self.order.payment_status, Order.PAYMENT_REFUNDED)


# ---------------------------------------------------------------------
# 2. PRIVACY — orders never leak across users
# ---------------------------------------------------------------------
class OrderPrivacyTests(TestCase):
    """Contract: a user only ever sees orders where they're buyer/seller —
    not other users' orders, even via direct ID access."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.stranger = make_user("stranger@campus.edu")
        self.order = Order.objects.create(buyer=self.buyer, seller=self.seller, total_price=Decimal("300.00"))

    def test_stranger_does_not_see_order_in_list(self):
        self.client.force_authenticate(user=self.stranger)
        response = self.client.get("/api/v1/orders/")
        ids = [o["id"] for o in (response.data["results"] if "results" in response.data else response.data)]
        self.assertNotIn(self.order.id, ids)

    def test_stranger_cannot_retrieve_order_by_id(self):
        self.client.force_authenticate(user=self.stranger)
        response = self.client.get(f"/api/v1/orders/{self.order.id}/")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_buyer_and_seller_can_both_retrieve_the_order(self):
        self.client.force_authenticate(user=self.buyer)
        self.assertEqual(self.client.get(f"/api/v1/orders/{self.order.id}/").status_code, status.HTTP_200_OK)

        self.client.force_authenticate(user=self.seller)
        self.assertEqual(self.client.get(f"/api/v1/orders/{self.order.id}/").status_code, status.HTTP_200_OK)


# ---------------------------------------------------------------------
# 3. CART -> ORDER CREATION
# ---------------------------------------------------------------------
class CreateOrderFromCartTests(TestCase):
    """Contract: converting a cart into order(s) groups by seller,
    rejects empty carts, rejects unavailable products, and clears
    the cart items that were successfully converted."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller_a = make_user("seller_a@campus.edu")
        self.seller_b = make_user("seller_b@campus.edu")
        self.cart = Cart.objects.create(user=self.buyer)
        self.client.force_authenticate(user=self.buyer)

    def test_empty_cart_is_rejected(self):
        response = self.client.post("/api/v1/orders/create/", {"payment_method": "COD"}, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_valid_cart_creates_orders_grouped_by_seller(self):
        item_a = make_product(self.seller_a, "Book", "200.00")
        item_b = make_product(self.seller_b, "Pen", "50.00")
        CartItem.objects.create(cart=self.cart, product=item_a, quantity=2)
        CartItem.objects.create(cart=self.cart, product=item_b, quantity=1)

        response = self.client.post("/api/v1/orders/create/", {"payment_method": "COD"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(len(response.data), 2)  # one order per seller

        orders_total = sorted(Decimal(o["total_price"]) for o in response.data)
        self.assertEqual(orders_total, [Decimal("50.00"), Decimal("400.00")])

        # Cart should be emptied after successful conversion.
        self.assertEqual(self.cart.items.count(), 0)

    def test_unavailable_product_in_cart_blocks_entire_checkout(self):
        item = make_product(self.seller_a, "Old Laptop", "10000.00")
        item.is_available = False
        item.save(update_fields=["is_available"])
        CartItem.objects.create(cart=self.cart, product=item, quantity=1)

        response = self.client.post("/api/v1/orders/create/", {"payment_method": "COD"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Order.objects.count(), 0)
        # Cart item must NOT be removed since checkout failed.
        self.assertEqual(self.cart.items.count(), 1)


# ---------------------------------------------------------------------
# 4. ROLE-GATED ACTIONS
# ---------------------------------------------------------------------
class UpdateStatusPermissionTests(TestCase):
    """Contract: only the seller can update order status, and only
    through valid transitions."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.order = Order.objects.create(buyer=self.buyer, seller=self.seller, total_price=Decimal("500.00"))
        self.url = f"/api/v1/orders/{self.order.id}/update_status/"

    def test_buyer_cannot_update_status(self):
        self.client.force_authenticate(user=self.buyer)
        response = self.client.patch(self.url, {"status": "PAID"}, format="json")
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_seller_can_update_to_valid_status(self):
        self.client.force_authenticate(user=self.seller)
        response = self.client.patch(self.url, {"status": "PAID"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, Order.STATUS_PAID)
        self.assertEqual(self.order.payment_status, Order.PAYMENT_SUCCESS)

    def test_seller_cannot_make_invalid_transition(self):
        self.client.force_authenticate(user=self.seller)
        response = self.client.patch(self.url, {"status": "DELIVERED"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, Order.STATUS_PENDING)  # unchanged


class CancelOrderTests(TestCase):
    """Contract: only the buyer can cancel, only while PENDING/PAID,
    and cancelling restores product availability."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Chair", "300.00")
        self.product.is_available = False  # simulate "reserved" by this order
        self.product.save(update_fields=["is_available"])

        self.order = Order.objects.create(buyer=self.buyer, seller=self.seller, total_price=Decimal("300.00"))
        OrderItem.objects.create(order=self.order, product=self.product, product_title="Chair",
                                  price=Decimal("300.00"), quantity=1)
        self.url = f"/api/v1/orders/{self.order.id}/cancel/"

    def test_seller_cannot_cancel_order(self):
        self.client.force_authenticate(user=self.seller)
        response = self.client.post(self.url)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_buyer_can_cancel_pending_order_and_product_becomes_available_again(self):
        self.client.force_authenticate(user=self.buyer)
        response = self.client.post(self.url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.product.refresh_from_db()
        self.assertEqual(self.order.status, Order.STATUS_CANCELLED)
        self.assertTrue(self.product.is_available)

    def test_buyer_cannot_cancel_shipped_order(self):
        self.order.status = Order.STATUS_PAID
        self.order.save(update_fields=["status"])
        self.order.status = Order.STATUS_SHIPPED
        self.order.save(update_fields=["status"])

        self.client.force_authenticate(user=self.buyer)
        response = self.client.post(self.url)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class ConfirmDeliveryTests(TestCase):
    """Contract: only the buyer can confirm delivery, and only once
    the order has actually been shipped."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.order = Order.objects.create(buyer=self.buyer, seller=self.seller, total_price=Decimal("300.00"))
        self.url = f"/api/v1/orders/{self.order.id}/confirm_delivery/"

    def test_cannot_confirm_delivery_before_shipped(self):
        self.client.force_authenticate(user=self.buyer)
        response = self.client.post(self.url)
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_buyer_can_confirm_delivery_after_shipped(self):
        self.order.status = Order.STATUS_PAID
        self.order.save(update_fields=["status"])
        self.order.status = Order.STATUS_SHIPPED
        self.order.save(update_fields=["status"])

        self.client.force_authenticate(user=self.buyer)
        response = self.client.post(self.url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, Order.STATUS_DELIVERED)

    def test_seller_cannot_confirm_delivery(self):
        self.order.status = Order.STATUS_PAID
        self.order.save(update_fields=["status"])
        self.order.status = Order.STATUS_SHIPPED
        self.order.save(update_fields=["status"])

        self.client.force_authenticate(user=self.seller)
        response = self.client.post(self.url)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)


# ---------------------------------------------------------------------
# 5. REFUND FLOW
# ---------------------------------------------------------------------
class RefundFlowTests(TestCase):
    """Contract: refund requests are buyer-initiated, only for
    paid/shipped/delivered orders, only once per order; decisions
    are seller/admin-only and approval cancels + refunds the order."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.order = Order.objects.create(
            buyer=self.buyer, seller=self.seller, total_price=Decimal("500.00"), status=Order.STATUS_PAID
        )
        Payment.objects.create(order=self.order, method="CARD", amount=Decimal("500.00"),
                                provider_payment_id="SIM-TEST-1", status=Order.PAYMENT_SUCCESS)
        self.request_url = f"/api/v1/orders/{self.order.id}/refund_request/"
        self.decision_url = f"/api/v1/orders/{self.order.id}/refund_decision/"

    def test_buyer_can_request_refund_on_paid_order(self):
        self.client.force_authenticate(user=self.buyer)
        response = self.client.post(self.request_url, {"reason": "Item damaged"}, format="json")
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertTrue(RefundRequest.objects.filter(order=self.order).exists())

    def test_cannot_request_refund_twice(self):
        self.client.force_authenticate(user=self.buyer)
        self.client.post(self.request_url, {"reason": "First reason"}, format="json")
        response = self.client.post(self.request_url, {"reason": "Second reason"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(RefundRequest.objects.filter(order=self.order).count(), 1)

    def test_seller_can_approve_refund_and_order_becomes_cancelled(self):
        self.client.force_authenticate(user=self.buyer)
        self.client.post(self.request_url, {"reason": "Not as described"}, format="json")

        self.client.force_authenticate(user=self.seller)
        response = self.client.patch(self.decision_url, {"decision": "APPROVE"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, Order.STATUS_CANCELLED)
        self.assertEqual(self.order.payment_status, Order.PAYMENT_REFUNDED)

    def test_buyer_cannot_decide_own_refund(self):
        self.client.force_authenticate(user=self.buyer)
        self.client.post(self.request_url, {"reason": "Wrong item"}, format="json")

        response = self.client.patch(self.decision_url, {"decision": "APPROVE"}, format="json")
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)