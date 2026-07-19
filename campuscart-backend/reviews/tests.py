# reviews/tests.py
"""
Real test coverage for the reviews app.

Business rules under test (read from models.py / serializers.py / views.py /
signals.py):
1. A user can only review a product they bought in a COMPLETED order —
   enforced independently in BOTH the serializer's validate_product()
   AND the view's perform_create() (belt-and-suspenders in the real
   code, so we test the end-to-end contract via the API).
2. Submitting a review for the same product twice UPDATES the existing
   review (update_or_create) rather than violating the unique_together
   constraint or creating a duplicate.
3. Rating must be between 1 and 5.
4. Only the review's author can edit/delete it; reading is public.
5. A signal recalculates the seller's aggregate rating/review count
   every time a review is saved OR deleted — this is derived data that
   must stay in sync automatically, not require a manual recompute.
"""

from decimal import Decimal
from django.test import TestCase
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient
from rest_framework import status

from .models import Review
from products.models import Product
from orders.models import Order, OrderItem

User = get_user_model()


def make_user(email):
    return User.objects.create_user(email=email, password="StrongPass!2024", name="Test", is_active=True)


def make_product(owner, title="Item", price="100.00"):
    return Product.objects.create(owner=owner, title=title, category="Other", price=Decimal(price))


def make_completed_order_with_item(buyer, seller, product):
    order = Order.objects.create(buyer=buyer, seller=seller, total_price=product.price,
                                  status=Order.STATUS_COMPLETED)
    OrderItem.objects.create(order=order, product=product, product_title=product.title,
                              price=product.price, quantity=1)
    return order


class ReviewEligibilityTests(TestCase):
    """Contract: only buyers with a COMPLETED order containing this
    product may post a review for it."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Textbook", "300.00")
        self.client.force_authenticate(user=self.buyer)
        self.url = "/api/v1/reviews/"

    def test_cannot_review_without_any_order(self):
        response = self.client.post(
            self.url, {"product": self.product.id, "rating": 5, "comment": "Great!"}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Review.objects.count(), 0)

    def test_cannot_review_with_pending_order_only(self):
        Order.objects.create(buyer=self.buyer, seller=self.seller, total_price=self.product.price)
        # order exists but status is PENDING, not COMPLETED

        response = self.client.post(
            self.url, {"product": self.product.id, "rating": 4, "comment": "ok"}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_can_review_after_completed_order(self):
        make_completed_order_with_item(self.buyer, self.seller, self.product)

        response = self.client.post(
            self.url, {"product": self.product.id, "rating": 5, "comment": "Exactly as described"}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(Review.objects.count(), 1)


class ReviewValidationTests(TestCase):
    """Contract: rating must be within 1-5."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Item", "100.00")
        make_completed_order_with_item(self.buyer, self.seller, self.product)
        self.client.force_authenticate(user=self.buyer)

    def test_rating_above_five_is_rejected(self):
        response = self.client.post(
            "/api/v1/reviews/", {"product": self.product.id, "rating": 6}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_rating_below_one_is_rejected(self):
        response = self.client.post(
            "/api/v1/reviews/", {"product": self.product.id, "rating": 0}, format="json"
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)


class ReviewUpdateOrCreateTests(TestCase):
    """Contract: resubmitting a review for the same product UPDATES
    the existing review instead of creating a duplicate or crashing
    on the unique_together constraint."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Item", "100.00")
        make_completed_order_with_item(self.buyer, self.seller, self.product)
        self.client.force_authenticate(user=self.buyer)
        self.url = "/api/v1/reviews/"

    def test_resubmitting_review_updates_not_duplicates(self):
        self.client.post(self.url, {"product": self.product.id, "rating": 3, "comment": "It's okay"}, format="json")
        response = self.client.post(
            self.url, {"product": self.product.id, "rating": 5, "comment": "Actually great!"}, format="json"
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(Review.objects.filter(user=self.buyer, product=self.product).count(), 1)

        review = Review.objects.get(user=self.buyer, product=self.product)
        self.assertEqual(review.rating, 5)
        self.assertEqual(review.comment, "Actually great!")


class ReviewOwnershipPermissionTests(TestCase):
    """Contract: anyone can read reviews; only the author can edit/delete."""

    def setUp(self):
        self.client = APIClient()
        self.buyer = make_user("buyer@campus.edu")
        self.other_user = make_user("other@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Item", "100.00")
        make_completed_order_with_item(self.buyer, self.seller, self.product)

        self.client.force_authenticate(user=self.buyer)
        create_response = self.client.post(
            "/api/v1/reviews/", {"product": self.product.id, "rating": 4, "comment": "Good"}, format="json"
        )
        self.review_id = create_response.data["id"]
        self.url = f"/api/v1/reviews/{self.review_id}/"

    def test_anonymous_user_can_read_review(self):
        self.client.force_authenticate(user=None)
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_non_author_cannot_update_review(self):
        self.client.force_authenticate(user=self.other_user)
        response = self.client.patch(self.url, {"rating": 1}, format="json")
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_non_author_cannot_delete_review(self):
        self.client.force_authenticate(user=self.other_user)
        response = self.client.delete(self.url)
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        self.assertTrue(Review.objects.filter(id=self.review_id).exists())


class SellerRatingAggregationTests(TestCase):
    """Contract: a signal recalculates the seller's aggregate rating
    and review count whenever a review is saved OR deleted — this is
    derived data, and must never go stale."""

    def setUp(self):
        self.buyer_a = make_user("buyer_a@campus.edu")
        self.buyer_b = make_user("buyer_b@campus.edu")
        self.seller = make_user("seller@campus.edu")
        self.product = make_product(self.seller, "Item", "100.00")
        make_completed_order_with_item(self.buyer_a, self.seller, self.product)
        make_completed_order_with_item(self.buyer_b, self.seller, self.product)

    def test_seller_rating_updates_when_review_created(self):
        Review.objects.create(product=self.product, user=self.buyer_a, rating=4)

        self.seller.refresh_from_db()
        self.assertEqual(self.seller.seller_rating, Decimal("4.00"))
        self.assertEqual(self.seller.total_reviews, 1)

    def test_seller_rating_averages_across_multiple_reviews(self):
        Review.objects.create(product=self.product, user=self.buyer_a, rating=4)
        Review.objects.create(product=self.product, user=self.buyer_b, rating=2)

        self.seller.refresh_from_db()
        self.assertAlmostEqual(float(self.seller.seller_rating), 3.0)
        self.assertEqual(self.seller.total_reviews, 2)

    def test_seller_rating_recalculates_after_review_deleted(self):
        r1 = Review.objects.create(product=self.product, user=self.buyer_a, rating=4)
        Review.objects.create(product=self.product, user=self.buyer_b, rating=2)

        r1.delete()

        self.seller.refresh_from_db()
        self.assertAlmostEqual(float(self.seller.seller_rating), 2.0)
        self.assertEqual(self.seller.total_reviews, 1)