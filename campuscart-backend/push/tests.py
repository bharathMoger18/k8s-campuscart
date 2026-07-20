# push/tests.py
"""
Real test coverage for the push app.

Business rules under test (read from models.py / views.py):
1. Subscribing validates the payload shape (endpoint + keys.p256dh +
   keys.auth) and upserts per (user, endpoint) — resubscribing with the
   same endpoint updates keys rather than creating a duplicate row.
2. The VAPID public key endpoint is intentionally public (AllowAny) —
   it's not a secret, the browser needs it to subscribe.
3. Sending a push notification talks to a THIRD-PARTY push service via
   `pywebpush.webpush()` — a real network call. Same principle as the
   Stripe tests: mock at the SDK boundary, test OUR reaction to success
   and failure, never call a real push service in tests.
4. A WebPushException (e.g. the subscription expired/was revoked) means
   we clean up that dead subscription — this is real self-healing
   behavior worth locking in.
5. Notifications are strictly per-user: listing, marking read, and
   marking-all-read must never leak or touch another user's rows.
"""

from unittest.mock import patch
from django.test import TestCase
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient
from rest_framework import status

from pywebpush import WebPushException

from .models import PushSubscription, PushNotification

User = get_user_model()


def make_user(email):
    return User.objects.create_user(email=email, password="StrongPass!2024", name="Test", is_active=True)


class VAPIDPublicKeyTests(TestCase):
    """Contract: the public key endpoint requires no authentication —
    it's meant to be public, the browser needs it before it can
    subscribe at all."""

    def test_public_key_accessible_without_auth(self):
        client = APIClient()
        response = client.get("/api/v1/push/public_key/")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("publicKey", response.data)


class PushSubscribeTests(TestCase):
    """Contract: subscribing validates the payload and upserts by
    (user, endpoint) rather than duplicating on resubscribe."""

    def setUp(self):
        self.client = APIClient()
        self.user = make_user("buyer@campus.edu")
        self.client.force_authenticate(user=self.user)
        self.url = "/api/v1/push/subscribe/"
        self.valid_payload = {
            "endpoint": "https://fcm.googleapis.com/fcm/send/fake-endpoint-123",
            "keys": {"p256dh": "fake_p256dh_key", "auth": "fake_auth_key"},
        }

    def test_unauthenticated_cannot_subscribe(self):
        client = APIClient()
        response = client.post(self.url, self.valid_payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_missing_keys_rejected(self):
        response = self.client.post(
            self.url, {"endpoint": "https://fcm.googleapis.com/fake"}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_valid_subscription_is_created(self):
        response = self.client.post(self.url, self.valid_payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(PushSubscription.objects.filter(user=self.user).count(), 1)

    def test_resubscribing_same_endpoint_updates_not_duplicates(self):
        self.client.post(self.url, self.valid_payload, format="json")

        updated_payload = {
            "endpoint": self.valid_payload["endpoint"],
            "keys": {"p256dh": "new_p256dh_key", "auth": "new_auth_key"},
        }
        self.client.post(self.url, updated_payload, format="json")

        self.assertEqual(PushSubscription.objects.filter(user=self.user).count(), 1)
        sub = PushSubscription.objects.get(user=self.user)
        self.assertEqual(sub.p256dh, "new_p256dh_key")

    def test_delete_requires_endpoint(self):
        response = self.client.delete(self.url, {}, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_delete_removes_subscription(self):
        self.client.post(self.url, self.valid_payload, format="json")

        response = self.client.delete(self.url, {"endpoint": self.valid_payload["endpoint"]}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(PushSubscription.objects.filter(user=self.user).count(), 0)


class SendPushDemoTests(TestCase):
    """Contract: sending logs a PushNotification either way, and the
    real webpush() call is mocked — we test OUR reaction to Web Push
    success/failure, not the push service itself."""

    def setUp(self):
        self.client = APIClient()
        self.user = make_user("buyer@campus.edu")
        self.client.force_authenticate(user=self.user)
        self.url = "/api/v1/push/send-demo/"

    def test_no_subscription_logs_undelivered_notification(self):
        response = self.client.post(self.url, {"title": "Hello"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        notif = PushNotification.objects.get(user=self.user)
        self.assertFalse(notif.delivered)

    @patch("push.views.webpush")
    def test_successful_push_marks_notification_delivered(self, mock_webpush):
        PushSubscription.objects.create(
            user=self.user, endpoint="https://fcm.googleapis.com/fake", p256dh="k1", auth="a1"
        )

        response = self.client.post(self.url, {"title": "Order shipped!"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        mock_webpush.assert_called_once()
        notif = PushNotification.objects.get(user=self.user)
        self.assertTrue(notif.delivered)

    @patch("push.views.webpush")
    def test_dead_subscription_is_removed_on_webpush_failure(self, mock_webpush):
        mock_webpush.side_effect = WebPushException("Subscription expired")
        sub = PushSubscription.objects.create(
            user=self.user, endpoint="https://fcm.googleapis.com/dead", p256dh="k1", auth="a1"
        )

        response = self.client.post(self.url, {"title": "Test"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertFalse(PushSubscription.objects.filter(id=sub.id).exists())
        notif = PushNotification.objects.get(user=self.user)
        self.assertFalse(notif.delivered)  # no successful sends


class NotificationsIsolationTests(TestCase):
    """Contract: listing, marking-read, and marking-all-read are
    strictly scoped per user — never touching another user's rows."""

    def setUp(self):
        self.client = APIClient()
        self.user_a = make_user("user_a@campus.edu")
        self.user_b = make_user("user_b@campus.edu")
        self.notif_a = PushNotification.objects.create(user=self.user_a, title="For A")
        self.notif_b = PushNotification.objects.create(user=self.user_b, title="For B")

    def test_list_only_shows_own_notifications(self):
        self.client.force_authenticate(user=self.user_a)
        response = self.client.get("/api/v1/push/notifications/")

        results = response.data["results"] if isinstance(response.data, dict) and "results" in response.data else response.data
        titles = [n["title"] for n in results]
        self.assertIn("For A", titles)
        self.assertNotIn("For B", titles)

    def test_cannot_mark_another_users_notification_as_read(self):
        self.client.force_authenticate(user=self.user_a)
        response = self.client.post(f"/api/v1/push/notifications/{self.notif_b.id}/mark-read/")

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        self.notif_b.refresh_from_db()
        self.assertFalse(self.notif_b.read)

    def test_mark_own_notification_as_read(self):
        self.client.force_authenticate(user=self.user_a)
        response = self.client.post(f"/api/v1/push/notifications/{self.notif_a.id}/mark-read/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.notif_a.refresh_from_db()
        self.assertTrue(self.notif_a.read)

    def test_mark_all_read_never_touches_other_users_notifications(self):
        another_for_a = PushNotification.objects.create(user=self.user_a, title="Second for A")

        self.client.force_authenticate(user=self.user_a)
        response = self.client.post("/api/v1/push/notifications/mark-all-read/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.notif_a.refresh_from_db()
        another_for_a.refresh_from_db()
        self.notif_b.refresh_from_db()

        self.assertTrue(self.notif_a.read)
        self.assertTrue(another_for_a.read)
        self.assertFalse(self.notif_b.read)  # untouched