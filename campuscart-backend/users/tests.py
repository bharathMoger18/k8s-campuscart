# users/tests.py
"""
Real test coverage for the users app.

Why these tests exist (not just "coverage for coverage's sake"):
- Registration, email verification, and JWT login are the security backbone
  of the whole application. If these silently break, every other app
  (orders, payments, etc.) becomes exploitable or unusable.
- Each test asserts a *contract*: given this input, the system MUST behave
  this way. If someone changes the code later and breaks the contract,
  these tests turn red — that's the whole point of a test suite in CI.
"""

from django.test import TestCase, override_settings
from django.contrib.auth import get_user_model
from django.contrib.auth.tokens import default_token_generator
from django.utils.http import urlsafe_base64_encode
from django.utils.encoding import force_bytes
from rest_framework.test import APIClient
from rest_framework import status

User = get_user_model()

# Force in-memory email backend for the whole test module.
# Without this, tests would try to open a real Gmail SMTP connection
# (settings.py currently hardcodes SMTP) — that's slow, network-dependent,
# and will straight-up fail in a CI environment with no internet/creds.
TEST_EMAIL_BACKEND = "django.core.mail.backends.locmem.EmailBackend"


@override_settings(EMAIL_BACKEND=TEST_EMAIL_BACKEND)
class RegistrationTests(TestCase):
    """Contract: only valid, matching, non-duplicate registrations succeed,
    and every new user starts INACTIVE until they verify their email."""

    def setUp(self):
        self.client = APIClient()
        self.url = "/api/v1/auth/register/"
        self.valid_payload = {
            "email": "student@campus.edu",
            "name": "Test Student",
            "password": "StrongPass!2024",
            "password2": "StrongPass!2024",
            "campus": "Main Campus",
            "phone": "9999999999",
        }

    def test_valid_registration_creates_active_user(self):
        response = self.client.post(self.url, self.valid_payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

        user = User.objects.get(email="student@campus.edu")
        # Product decision: no email verification step — active immediately.
        self.assertTrue(user.is_active)

        # No verification email should be sent at registration anymore.
        from django.core import mail
        self.assertEqual(len(mail.outbox), 0)

    def test_registered_user_can_login_immediately(self):
        self.client.post(self.url, self.valid_payload, format="json")

        login_response = self.client.post(
            "/api/v1/auth/token/",
            {"email": "student@campus.edu", "password": "StrongPass!2024"},
            format="json",
        )
        self.assertEqual(login_response.status_code, status.HTTP_200_OK)
        self.assertIn("access", login_response.data)

    def test_password_mismatch_is_rejected(self):
        payload = self.valid_payload.copy()
        payload["password2"] = "DifferentPass!2024"

        response = self.client.post(self.url, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(User.objects.filter(email="student@campus.edu").exists())

    def test_duplicate_email_is_rejected(self):
        User.objects.create_user(email="student@campus.edu", password="Existing!2024", name="Existing")

        response = self.client.post(self.url, self.valid_payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        # Only the original user should exist — no duplicate created.
        self.assertEqual(User.objects.filter(email="student@campus.edu").count(), 1)

    def test_weak_password_is_rejected(self):
        payload = self.valid_payload.copy()
        payload["password"] = "123"
        payload["password2"] = "123"

        response = self.client.post(self.url, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


@override_settings(EMAIL_BACKEND=TEST_EMAIL_BACKEND)
class InactiveAccountAndVerificationEndpointTests(TestCase):
    """Contract: a deactivated/inactive account (e.g. banned, or a leftover
    account from before this policy changed) still CANNOT obtain a JWT token.
    The verification endpoint itself is kept dormant but functional in case
    it's ever re-enabled — this locks in that it still works correctly."""

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            email="unverified@campus.edu",
            password="StrongPass!2024",
            name="Unverified User",
            is_active=False,  # e.g. manually deactivated, not a registration outcome anymore
        )
        self.token_url = "/api/v1/auth/token/"

    def test_login_blocked_for_inactive_account(self):
        response = self.client.post(
            self.token_url,
            {"email": "unverified@campus.edu", "password": "StrongPass!2024"},
            format="json",
        )
        # SimpleJWT's authenticate() rejects inactive users by default.
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_verification_endpoint_still_activates_and_allows_login(self):
        uid = urlsafe_base64_encode(force_bytes(self.user.pk))
        token = default_token_generator.make_token(self.user)

        verify_response = self.client.get(f"/api/v1/auth/verify/{uid}/{token}/")
        self.assertEqual(verify_response.status_code, status.HTTP_200_OK)

        self.user.refresh_from_db()
        self.assertTrue(self.user.is_active)

        login_response = self.client.post(
            self.token_url,
            {"email": "unverified@campus.edu", "password": "StrongPass!2024"},
            format="json",
        )
        self.assertEqual(login_response.status_code, status.HTTP_200_OK)
        self.assertIn("access", login_response.data)
        self.assertIn("refresh", login_response.data)

    def test_invalid_verification_token_is_rejected(self):
        uid = urlsafe_base64_encode(force_bytes(self.user.pk))
        bad_token = "invalid-token-value"

        response = self.client.get(f"/api/v1/auth/verify/{uid}/{bad_token}/")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

        self.user.refresh_from_db()
        self.assertFalse(self.user.is_active)  # must remain inactive


class ProfileAccessTests(TestCase):
    """Contract: /users/me/ requires authentication — no silent bypass."""

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            email="active@campus.edu",
            password="StrongPass!2024",
            name="Active User",
            is_active=True,
        )
        self.url = "/api/v1/users/me/"

    def test_unauthenticated_request_is_rejected(self):
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_authenticated_request_returns_own_profile(self):
        self.client.force_authenticate(user=self.user)
        response = self.client.get(self.url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["email"], "active@campus.edu")

    def test_authenticated_user_can_update_profile(self):
        self.client.force_authenticate(user=self.user)
        response = self.client.put(self.url, {"name": "Updated Name"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.user.refresh_from_db()
        self.assertEqual(self.user.name, "Updated Name")


class PublicUserDetailTests(TestCase):
    """Contract: public profile lookup exposes only safe fields,
    and returns a clean 404 (not a 500) for a nonexistent user."""

    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            email="seller@campus.edu",
            password="StrongPass!2024",
            name="Seller Name",
            is_active=True,
        )

    def test_existing_user_returns_public_fields(self):
        response = self.client.get(f"/api/v1/users/public/{self.user.id}/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["email"], "seller@campus.edu")
        self.assertEqual(response.data["name"], "Seller Name")

    def test_nonexistent_user_returns_404_not_crash(self):
        response = self.client.get("/api/v1/users/public/99999/")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)