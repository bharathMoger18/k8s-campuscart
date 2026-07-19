# cart/tests.py
"""
Real test coverage for the cart app.

Business rules under test (read from models.py / views.py):
1. Every user has exactly one cart, auto-created on first access
   (get_or_create) — never a duplicate, never a 404 for "no cart yet".
2. All cart actions require authentication.
3. Adding a product that's already in the cart INCREMENTS quantity
   rather than resetting it — this is the actual behavior in `add()`
   and it's easy to accidentally break with an "obvious" refactor.
4. Adding an invalid/soft-deleted product is rejected, not silently
   added as a broken cart line.
5. Removing a product not in the cart is a safe no-op, not an error.
6. Carts are strictly per-user — one user's actions never touch
   another user's cart, even though `get_or_create` runs on every call.
"""

from decimal import Decimal
from django.test import TestCase
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient
from rest_framework import status

from .models import Cart, CartItem
from products.models import Product

User = get_user_model()


def make_user(email):
    return User.objects.create_user(email=email, password="StrongPass!2024", name="Test", is_active=True)


def make_product(owner, title="Item", price="100.00"):
    return Product.objects.create(owner=owner, title=title, category="Other", price=Decimal(price))


class CartAuthenticationTests(TestCase):
    """Contract: every cart action requires authentication."""

    def setUp(self):
        self.client = APIClient()

    def test_unauthenticated_cannot_view_cart(self):
        response = self.client.get("/api/v1/cart/")
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_unauthenticated_cannot_add_to_cart(self):
        response = self.client.post("/api/v1/cart/add/", {"product_id": 1}, format="json")
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)


class CartAutoCreationTests(TestCase):
    """Contract: a cart is auto-created on first access, exactly one
    per user, never a 404 for 'you don't have a cart yet'."""

    def setUp(self):
        self.client = APIClient()
        self.user = make_user("buyer@campus.edu")
        self.client.force_authenticate(user=self.user)

    def test_first_view_creates_cart(self):
        self.assertEqual(Cart.objects.filter(user=self.user).count(), 0)

        response = self.client.get("/api/v1/cart/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(Cart.objects.filter(user=self.user).count(), 1)

    def test_repeated_access_never_creates_duplicate_cart(self):
        self.client.get("/api/v1/cart/")
        self.client.get("/api/v1/cart/")
        self.client.post("/api/v1/cart/clear/")

        self.assertEqual(Cart.objects.filter(user=self.user).count(), 1)


class AddToCartTests(TestCase):
    """Contract: adding validates the product, and adding the SAME
    product twice increments quantity rather than resetting it."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Textbook", "250.00")
        self.client.force_authenticate(user=self.buyer)

    def test_missing_product_id_is_rejected(self):
        response = self.client.post("/api/v1/cart/add/", {"quantity": 1}, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_nonexistent_product_is_rejected(self):
        response = self.client.post("/api/v1/cart/add/", {"product_id": 99999}, format="json")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_soft_deleted_product_cannot_be_added(self):
        self.product.is_deleted = True
        self.product.save(update_fields=["is_deleted"])

        response = self.client.post("/api/v1/cart/add/", {"product_id": self.product.id}, format="json")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_adding_new_product_creates_item_with_given_quantity(self):
        response = self.client.post(
            "/api/v1/cart/add/", {"product_id": self.product.id, "quantity": 3}, format="json"
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        item = CartItem.objects.get(cart__user=self.buyer, product=self.product)
        self.assertEqual(item.quantity, 3)

    def test_adding_same_product_again_increments_not_resets_quantity(self):
        self.client.post("/api/v1/cart/add/", {"product_id": self.product.id, "quantity": 2}, format="json")
        self.client.post("/api/v1/cart/add/", {"product_id": self.product.id, "quantity": 3}, format="json")

        item = CartItem.objects.get(cart__user=self.buyer, product=self.product)
        self.assertEqual(item.quantity, 5)  # 2 + 3, not just 3

    def test_default_quantity_is_one_when_not_specified(self):
        self.client.post("/api/v1/cart/add/", {"product_id": self.product.id}, format="json")

        item = CartItem.objects.get(cart__user=self.buyer, product=self.product)
        self.assertEqual(item.quantity, 1)


class RemoveFromCartTests(TestCase):
    """Contract: removing a specific product deletes only that line;
    removing something not in the cart is a safe no-op."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product_a = make_product(self.seller, "Item A", "100.00")
        self.product_b = make_product(self.seller, "Item B", "200.00")
        self.client.force_authenticate(user=self.buyer)

        self.client.post("/api/v1/cart/add/", {"product_id": self.product_a.id}, format="json")
        self.client.post("/api/v1/cart/add/", {"product_id": self.product_b.id}, format="json")

    def test_remove_deletes_only_specified_product(self):
        response = self.client.post("/api/v1/cart/remove/", {"product_id": self.product_a.id}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        cart = Cart.objects.get(user=self.buyer)
        remaining_products = list(cart.items.values_list("product_id", flat=True))
        self.assertNotIn(self.product_a.id, remaining_products)
        self.assertIn(self.product_b.id, remaining_products)

    def test_removing_product_not_in_cart_is_safe_noop(self):
        other_product = make_product(self.seller, "Never Added", "50.00")

        response = self.client.post("/api/v1/cart/remove/", {"product_id": other_product.id}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        cart = Cart.objects.get(user=self.buyer)
        self.assertEqual(cart.items.count(), 2)  # unchanged


class ClearCartTests(TestCase):
    """Contract: clearing empties all items but leaves the cart itself intact."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Item", "100.00")
        self.client.force_authenticate(user=self.buyer)
        self.client.post("/api/v1/cart/add/", {"product_id": self.product.id}, format="json")

    def test_clear_empties_cart(self):
        response = self.client.post("/api/v1/cart/clear/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        cart = Cart.objects.get(user=self.buyer)
        self.assertEqual(cart.items.count(), 0)
        # The Cart row itself should still exist, only items are cleared.
        self.assertTrue(Cart.objects.filter(user=self.buyer).exists())


class CartIsolationTests(TestCase):
    """Contract: one user's cart actions never touch another user's
    cart, even though get_or_create runs on every request."""

    def setUp(self):
        self.client = APIClient()
        self.buyer_a = make_user("buyer_a@campus.edu")
        self.buyer_b = make_user("buyer_b@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Shared Item", "150.00")

    def test_adding_to_one_users_cart_does_not_affect_another(self):
        self.client.force_authenticate(user=self.buyer_a)
        self.client.post("/api/v1/cart/add/", {"product_id": self.product.id, "quantity": 5}, format="json")

        self.client.force_authenticate(user=self.buyer_b)
        response = self.client.get("/api/v1/cart/")

        self.assertEqual(response.data["total_items"], 0)  # buyer_b's cart is untouched

        cart_a = Cart.objects.get(user=self.buyer_a)
        self.assertEqual(cart_a.items.first().quantity, 5)  # buyer_a's data intact