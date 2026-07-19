# chat/tests.py
"""
Real test coverage for the chat app.

Business rules under test (read from models.py / views.py):
1. Only authenticated users can create conversations or read messages.
2. A conversation's message list should ONLY be visible to its actual
   participants — not any authenticated user who knows/guesses the ID.
3. Two DIFFERENT pairs of users messaging about the SAME product must
   get SEPARATE conversations — never merged into one, which would
   leak private messages between unrelated buyers.
4. A user only ever sees conversations they're a participant of.
"""

from django.test import TestCase
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient
from rest_framework import status

from decimal import Decimal
from .models import Conversation, Message
from products.models import Product

User = get_user_model()


def make_user(email):
    return User.objects.create_user(email=email, password="StrongPass!2024", name="Test", is_active=True)


def make_product(owner, title="Item", price="100.00"):
    return Product.objects.create(owner=owner, title=title, category="Other", price=Decimal(price))


class ConversationAuthenticationTests(TestCase):
    def setUp(self):
        self.client = APIClient()

    def test_unauthenticated_cannot_list_conversations(self):
        response = self.client.get("/api/v1/conversations/")
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)


class ConversationCreationTests(TestCase):
    """Contract: creating a conversation requires a valid product and
    other_user, and adds both the requester and the other user as
    participants."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Bike", "3000.00")
        self.client.force_authenticate(user=self.buyer)
        self.url = "/api/v1/conversations/"

    def test_missing_fields_rejected(self):
        response = self.client.post(self.url, {"product": self.product.id}, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_invalid_product_rejected(self):
        response = self.client.post(
            self.url, {"product": 99999, "other_user": self.seller.id}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_valid_creation_adds_both_participants(self):
        response = self.client.post(
            self.url, {"product": self.product.id, "other_user": self.seller.id}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

        conversation = Conversation.objects.get(id=response.data["id"])
        participant_ids = set(conversation.participants.values_list("id", flat=True))
        self.assertEqual(participant_ids, {self.buyer.id, self.seller.id})


class ConversationIsolationTests(TestCase):
    """Contract: two DIFFERENT buyers messaging the same seller about
    the SAME product must land in SEPARATE conversations — never
    merged, which would leak one buyer's messages to the other."""

    def setUp(self):
        self.client = APIClient()
        self.buyer_a = make_user("buyer_a@campus.edu")
        self.buyer_b = make_user("buyer_b@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Guitar", "5000.00")
        self.url = "/api/v1/conversations/"

    def test_different_buyers_same_product_get_separate_conversations(self):
        self.client.force_authenticate(user=self.buyer_a)
        resp_a = self.client.post(
            self.url, {"product": self.product.id, "other_user": self.seller.id}, format="json"
        )

        self.client.force_authenticate(user=self.buyer_b)
        resp_b = self.client.post(
            self.url, {"product": self.product.id, "other_user": self.seller.id}, format="json"
        )

        self.assertNotEqual(resp_a.data["id"], resp_b.data["id"])

    def test_buyer_b_cannot_see_buyer_a_conversation_in_list(self):
        self.client.force_authenticate(user=self.buyer_a)
        conv_a = self.client.post(
            self.url, {"product": self.product.id, "other_user": self.seller.id}, format="json"
        ).data["id"]

        self.client.force_authenticate(user=self.buyer_b)
        self.client.post(self.url, {"product": self.product.id, "other_user": self.seller.id}, format="json")

        response = self.client.get(self.url)
        results = response.data["results"] if isinstance(response.data, dict) and "results" in response.data else response.data
        ids = [c["id"] for c in results]
        self.assertNotIn(conv_a, ids)


class MessageAccessControlTests(TestCase):
    """Contract: only participants of a conversation can read its
    messages — a stranger authenticated user must NOT be able to read
    someone else's private conversation just by guessing the ID."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.stranger = make_user("stranger@campus.edu")
        self.product = make_product(self.seller, "Camera", "8000.00")

        self.conversation = Conversation.objects.create(product=self.product)
        self.conversation.participants.add(self.buyer, self.seller)
        Message.objects.create(conversation=self.conversation, sender=self.buyer, text="Is this still available?")

        self.url = f"/api/v1/conversations/{self.conversation.id}/messages/"

    def test_participant_can_read_messages(self):
        self.client.force_authenticate(user=self.buyer)
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        results = response.data["results"] if isinstance(response.data, dict) and "results" in response.data else response.data
        self.assertEqual(len(results), 1)

    def test_stranger_cannot_read_messages_of_conversation_they_are_not_in(self):
        self.client.force_authenticate(user=self.stranger)
        response = self.client.get(self.url)
        # A filtered list() naturally returns 200 with zero results for a
        # non-participant — this is fine and even preferable: it doesn't
        # confirm or deny whether the conversation exists at all.
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        results = response.data["results"] if isinstance(response.data, dict) and "results" in response.data else response.data
        self.assertEqual(len(results), 0)