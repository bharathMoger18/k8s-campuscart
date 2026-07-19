# wishlist/tests.py
"""
Real test coverage for the wishlist app.

Business rules under test (read from models.py / views.py):
1. Wishlist auto-created per user, same get_or_create pattern as cart.
2. Adding the same product twice does NOT create a duplicate item
   (unique_together + get_or_create) — the second add just reports
   "already in wishlist".
3. Invalid/soft-deleted products can't be added.
4. move_to_cart TRANSFERS an item: removes it from the wishlist AND
   adds/increments it in the cart, atomically from the user's view.
5. move_to_cart rejects a product that's no longer available, and
   rejects a product_id that isn't actually in the wishlist.
"""

from decimal import Decimal
from django.test import TestCase
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient
from rest_framework import status

from .models import Wishlist, WishlistItem
from products.models import Product
from cart.models import Cart, CartItem

User = get_user_model()


def make_user(email):
    return User.objects.create_user(email=email, password="StrongPass!2024", name="Test", is_active=True)


def make_product(owner, title="Item", price="100.00"):
    return Product.objects.create(owner=owner, title=title, category="Other", price=Decimal(price))


class WishlistAuthenticationTests(TestCase):
    """Contract: wishlist actions require authentication."""

    def setUp(self):
        self.client = APIClient()

    def test_unauthenticated_cannot_view_wishlist(self):
        response = self.client.get("/api/v1/wishlist/")
        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)


class AddToWishlistTests(TestCase):
    """Contract: adding validates the product and never creates a
    duplicate entry for the same product."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Jacket", "800.00")
        self.client.force_authenticate(user=self.buyer)

    def test_invalid_product_is_rejected(self):
        response = self.client.post("/api/v1/wishlist/add/", {"product_id": 99999}, format="json")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_soft_deleted_product_cannot_be_added(self):
        self.product.is_deleted = True
        self.product.save(update_fields=["is_deleted"])

        response = self.client.post("/api/v1/wishlist/add/", {"product_id": self.product.id}, format="json")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_adding_product_creates_wishlist_item(self):
        response = self.client.post("/api/v1/wishlist/add/", {"product_id": self.product.id}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["message"], "Product added to wishlist.")
        self.assertEqual(WishlistItem.objects.filter(wishlist__user=self.buyer, product=self.product).count(), 1)

    def test_adding_same_product_twice_does_not_duplicate(self):
        self.client.post("/api/v1/wishlist/add/", {"product_id": self.product.id}, format="json")
        response = self.client.post("/api/v1/wishlist/add/", {"product_id": self.product.id}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["message"], "Product already in wishlist.")
        self.assertEqual(WishlistItem.objects.filter(wishlist__user=self.buyer, product=self.product).count(), 1)

    def test_seller_can_wishlist_own_product_without_error(self):
        """notify_seller_wishlist_like silently skips self-notification,
        but the add itself should still succeed."""
        self.client.force_authenticate(user=self.seller)
        response = self.client.post("/api/v1/wishlist/add/", {"product_id": self.product.id}, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK)


class RemoveAndClearWishlistTests(TestCase):
    """Contract: remove deletes only the specified item; clear empties
    everything; removing something absent is a safe no-op."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product_a = make_product(self.seller, "Item A", "100.00")
        self.product_b = make_product(self.seller, "Item B", "200.00")
        self.client.force_authenticate(user=self.buyer)
        self.client.post("/api/v1/wishlist/add/", {"product_id": self.product_a.id}, format="json")
        self.client.post("/api/v1/wishlist/add/", {"product_id": self.product_b.id}, format="json")

    def test_remove_deletes_only_specified_item(self):
        response = self.client.post("/api/v1/wishlist/remove/", {"product_id": self.product_a.id}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        wishlist = Wishlist.objects.get(user=self.buyer)
        remaining = list(wishlist.items.values_list("product_id", flat=True))
        self.assertNotIn(self.product_a.id, remaining)
        self.assertIn(self.product_b.id, remaining)

    def test_removing_absent_item_is_safe_noop(self):
        other_product = make_product(self.seller, "Never Wishlisted", "50.00")
        response = self.client.post("/api/v1/wishlist/remove/", {"product_id": other_product.id}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        wishlist = Wishlist.objects.get(user=self.buyer)
        self.assertEqual(wishlist.items.count(), 2)

    def test_clear_empties_wishlist(self):
        response = self.client.post("/api/v1/wishlist/clear/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        wishlist = Wishlist.objects.get(user=self.buyer)
        self.assertEqual(wishlist.items.count(), 0)


class MoveToCartTests(TestCase):
    """Contract: moving an item to the cart removes it from the
    wishlist AND adds/increments it in the cart — a real transfer,
    not a copy."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Headphones", "1500.00")
        self.client.force_authenticate(user=self.buyer)
        self.client.post("/api/v1/wishlist/add/", {"product_id": self.product.id}, format="json")
        self.url = "/api/v1/wishlist/move-to-cart/"

    def test_missing_product_id_is_rejected(self):
        response = self.client.post(self.url, {}, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_product_not_in_wishlist_is_rejected(self):
        other_product = make_product(self.seller, "Not Wishlisted", "50.00")
        response = self.client.post(self.url, {"product_id": other_product.id}, format="json")
        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)

    def test_moving_item_removes_from_wishlist_and_adds_to_cart(self):
        response = self.client.post(self.url, {"product_id": self.product.id}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)

        wishlist = Wishlist.objects.get(user=self.buyer)
        self.assertEqual(wishlist.items.filter(product=self.product).count(), 0)

        cart = Cart.objects.get(user=self.buyer)
        cart_item = CartItem.objects.get(cart=cart, product=self.product)
        self.assertEqual(cart_item.quantity, 1)

    def test_moving_item_already_in_cart_increments_quantity(self):
        cart = Cart.objects.create(user=self.buyer)
        CartItem.objects.create(cart=cart, product=self.product, quantity=2)

        response = self.client.post(self.url, {"product_id": self.product.id}, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        cart_item = CartItem.objects.get(cart=cart, product=self.product)
        self.assertEqual(cart_item.quantity, 3)  # 2 + 1, not reset

    def test_cannot_move_soft_deleted_product_to_cart(self):
        self.product.is_deleted = True
        self.product.save(update_fields=["is_deleted"])

        response = self.client.post(self.url, {"product_id": self.product.id}, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

        # Item should remain in wishlist since the move failed.
        wishlist = Wishlist.objects.get(user=self.buyer)
        self.assertEqual(wishlist.items.filter(product=self.product).count(), 1)