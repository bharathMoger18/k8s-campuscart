from django.test import TestCase


class ReadyzTests(TestCase):
    def test_readyz_returns_ok(self):
        response = self.client.get("/api/v1/readyz", secure=True)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "ok"})
