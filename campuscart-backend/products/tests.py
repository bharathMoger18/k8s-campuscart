# products/tests.py
"""
Real test coverage for the products app.

Business rules under test (the actual contract, found by reading the code —
not assumed):
1. Anyone (even anonymous) can browse products — read is public.
2. Creating/updating/deleting requires authentication.
3. Only the OWNER of a product can update or delete it — another
   authenticated user must be blocked (403), not silently allowed.
4. Deleting a product is a SOFT delete: the row survives in the DB
   (is_deleted=True, is_available=False, deleted_at set), and it
   disappears from the public list/detail endpoints afterward.
5. Filtering (price range, category, availability) actually filters.
6. The seller's own product list only ever shows their own products,
   even if other sellers have products too.
"""

from decimal import Decimal
from django.test import TestCase
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient
from rest_framework import status

from .models import Product

User = get_user_model()


def make_user(email, active=True):
    return User.objects.create_user(email=email, password="StrongPass!2024", name="Test", is_active=active)


class ProductVisibilityTests(TestCase):
    """Contract: product browsing is public, no login required."""

    def setUp(self):
        self.client = APIClient()
        self.owner = make_user("owner@campus.edu")
        self.product = Product.objects.create(
            owner=self.owner, title="Used Textbook", category="Books", price=Decimal("250.00")
        )

    def test_anonymous_user_can_list_products(self):
        response = self.client.get("/api/v1/products/")
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_anonymous_user_can_retrieve_single_product(self):
        response = self.client.get(f"/api/v1/products/{self.product.id}/")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["title"], "Used Textbook")


class ProductCreationTests(TestCase):
    """Contract: creating a product requires authentication, and the
    owner is set to the requesting user — never client-supplied."""

    def setUp(self):
        self.client = APIClient()
        self.user = make_user("seller@campus.edu")
        self.payload = {
            "title": "Scientific Calculator",
            "description": "Barely used",
            "category": "Electronics",
            "price": "899.00",
        }

    def test_unauthenticated_create_is_rejected(self):
        response = self.client.post("/api/v1/products/", self.payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_authenticated_create_sets_requesting_user_as_owner(self):
        self.client.force_authenticate(user=self.user)
        response = self.client.post("/api/v1/products/", self.payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        product = Product.objects.get(id=response.data["id"])
        self.assertEqual(product.owner, self.user)


class ProductOwnershipPermissionTests(TestCase):
    """Contract: only the owner can modify or delete their own product.
    A different authenticated user must be blocked with 403, not allowed
    through and not crashing."""

    def setUp(self):
        self.client = APIClient()
        self.owner = make_user("owner@campus.edu")
        self.other_user = make_user("other@campus.edu")
        self.product = Product.objects.create(
            owner=self.owner, title="Desk Lamp", category="Other", price=Decimal("400.00")
        )
        self.url = f"/api/v1/products/{self.product.id}/"

    def test_owner_can_update_their_product(self):
        self.client.force_authenticate(user=self.owner)
        response = self.client.patch(self.url, {"price": "350.00"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.product.refresh_from_db()
        self.assertEqual(self.product.price, Decimal("350.00"))

    def test_non_owner_cannot_update_product(self):
        self.client.force_authenticate(user=self.other_user)
        response = self.client.patch(self.url, {"price": "1.00"}, format="json")

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.product.refresh_from_db()
        self.assertEqual(self.product.price, Decimal("400.00"))  # unchanged

    def test_non_owner_cannot_delete_product(self):
        self.client.force_authenticate(user=self.other_user)
        response = self.client.delete(self.url)

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.product.refresh_from_db()
        self.assertFalse(self.product.is_deleted)


class ProductSoftDeleteTests(TestCase):
    """Contract: deleting a product never actually removes the row —
    it's a soft delete, and the product must vanish from public endpoints
    afterward while still existing in the database for audit/history."""

    def setUp(self):
        self.client = APIClient()
        self.owner = make_user("owner@campus.edu")
        self.product = Product.objects.create(
            owner=self.owner, title="Bluetooth Speaker", category="Electronics", price=Decimal("1200.00")
        )
        self.url = f"/api/v1/products/{self.product.id}/"

    def test_owner_delete_soft_deletes_not_hard_deletes(self):
        self.client.force_authenticate(user=self.owner)
        response = self.client.delete(self.url)

        self.assertEqual(response.status_code, status.HTTP_204_NO_CONTENT)

        # Row must still exist in the DB.
        product = Product.objects.get(id=self.product.id)
        self.assertTrue(product.is_deleted)
        self.assertFalse(product.is_available)
        self.assertIsNotNone(product.deleted_at)

    def test_soft_deleted_product_disappears_from_public_list(self):
        self.client.force_authenticate(user=self.owner)
        self.client.delete(self.url)

        list_response = self.client.get("/api/v1/products/")
        product_ids = [p["id"] for p in list_response.data["results"]] if "results" in list_response.data else [p["id"] for p in list_response.data]
        self.assertNotIn(self.product.id, product_ids)

    def test_soft_deleted_product_returns_404_on_retrieve(self):
        self.client.force_authenticate(user=self.owner)
        self.client.delete(self.url)

        response = self.client.get(self.url)
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)


class ProductFilteringTests(TestCase):
    """Contract: price range, category, and availability filters actually
    narrow down the results — not just accepted as query params and ignored."""

    def setUp(self):
        self.client = APIClient()
        self.owner = make_user("owner@campus.edu")
        Product.objects.create(owner=self.owner, title="Cheap Pen", category="Other", price=Decimal("20.00"))
        Product.objects.create(owner=self.owner, title="Mid Book", category="Books", price=Decimal("300.00"))
        Product.objects.create(owner=self.owner, title="Laptop", category="Electronics", price=Decimal("45000.00"))

    def test_filter_by_category(self):
        response = self.client.get("/api/v1/products/?category=Books")
        results = response.data["results"] if "results" in response.data else response.data
        self.assertTrue(all(p["category"] == "Books" for p in results))
        self.assertEqual(len(results), 1)

    def test_filter_by_price_range(self):
        response = self.client.get("/api/v1/products/?min_price=100&max_price=1000")
        results = response.data["results"] if "results" in response.data else response.data
        titles = [p["title"] for p in results]
        self.assertIn("Mid Book", titles)
        self.assertNotIn("Cheap Pen", titles)
        self.assertNotIn("Laptop", titles)


class SellerProductScopeTests(TestCase):
    """Contract: a seller's own product dashboard NEVER leaks another
    seller's products, even though both exist in the same table."""

    def setUp(self):
        self.client = APIClient()
        self.seller_a = make_user("seller_a@campus.edu")
        self.seller_b = make_user("seller_b@campus.edu")
        Product.objects.create(owner=self.seller_a, title="A's Item", category="Other", price=Decimal("100.00"))
        Product.objects.create(owner=self.seller_b, title="B's Item", category="Other", price=Decimal("200.00"))

    def test_unauthenticated_cannot_access_seller_products(self):
        response = self.client.get("/api/v1/seller/products/")
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_seller_only_sees_own_products(self):
        self.client.force_authenticate(user=self.seller_a)
        response = self.client.get("/api/v1/seller/products/")

        results = response.data["results"] if "results" in response.data else response.data
        titles = [p["title"] for p in results]
        self.assertIn("A's Item", titles)
        self.assertNotIn("B's Item", titles)