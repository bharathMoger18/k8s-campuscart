# users/views.py

from rest_framework import generics, permissions, status
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework.exceptions import ValidationError
from django.contrib.auth import get_user_model
from django.contrib.auth.tokens import default_token_generator
from django.utils.http import urlsafe_base64_decode
from django.core.exceptions import ObjectDoesNotExist
from django.contrib.auth.hashers import make_password

from .serializers import RegisterSerializer, UserSerializer
from .models import User
from .utils import send_password_reset_email
from .metrics import user_registrations_total
from .metrics import user_logins_total
from rest_framework_simplejwt.views import TokenObtainPairView
from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import AllowAny

User = get_user_model()


# ---------------------------
# Registration & User Profile
# ---------------------------

class RegisterView(generics.CreateAPIView):
    """
    Handles user registration. Users are active immediately upon
    registration — no email verification step required.
    """
    queryset = User.objects.all()
    permission_classes = (permissions.AllowAny,)
    serializer_class = RegisterSerializer

    def create(self, request, *args, **kwargs):
        try:
            response = super().create(request, *args, **kwargs)
        except ValidationError:
            user_registrations_total.labels(status="failed").inc()
            raise
        return response

    def perform_create(self, serializer):
        user = serializer.save(is_active=True)
        user_registrations_total.labels(status="success").inc()
        return user


class MeView(APIView):
    """
    Handles authenticated user profile retrieval and updates.
    """
    permission_classes = (permissions.IsAuthenticated,)

    def get(self, request):
        serializer = UserSerializer(request.user)
        return Response(serializer.data)

    def put(self, request):
        serializer = UserSerializer(request.user, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)


# ---------------------------
# Email Verification (kept for optional future re-enable; unused at registration)
# ---------------------------

class VerifyEmailView(APIView):
    """
    Verifies user's email when clicking on the verification link.
    """
    permission_classes = [permissions.AllowAny]

    def get(self, request, uidb64, token):
        try:
            uid = urlsafe_base64_decode(uidb64).decode()
            user = User.objects.get(pk=uid)
        except (ObjectDoesNotExist, ValueError, TypeError, OverflowError):
            return Response({"detail": "Invalid link."}, status=status.HTTP_400_BAD_REQUEST)

        if default_token_generator.check_token(user, token):
            user.is_active = True
            user.save(update_fields=["is_active"])
            return Response({"detail": "Email verified successfully!"})
        return Response({"detail": "Invalid or expired token."}, status=status.HTTP_400_BAD_REQUEST)


# ---------------------------
# Password Reset
# ---------------------------

class RequestPasswordResetView(APIView):
    """
    Sends a password reset email if the provided email exists.
    """
    permission_classes = [permissions.AllowAny]

    def post(self, request):
        email = request.data.get("email")
        try:
            user = User.objects.get(email=email)
            send_password_reset_email(user, request)
        except User.DoesNotExist:
            pass  # avoid revealing if user exists
        return Response({"detail": "If your email exists, you'll receive a reset link."})


class PasswordResetConfirmView(APIView):
    """
    Confirms the password reset via token and sets a new password.
    """
    permission_classes = [permissions.AllowAny]

    def post(self, request, uidb64, token):
        try:
            uid = urlsafe_base64_decode(uidb64).decode()
            user = User.objects.get(pk=uid)
        except (ObjectDoesNotExist, ValueError, TypeError, OverflowError):
            return Response({"detail": "Invalid link."}, status=status.HTTP_400_BAD_REQUEST)

        if not default_token_generator.check_token(user, token):
            return Response({"detail": "Invalid or expired token."}, status=status.HTTP_400_BAD_REQUEST)

        new_password = request.data.get("password")
        if not new_password:
            return Response({"detail": "Password required."}, status=status.HTTP_400_BAD_REQUEST)

        user.password = make_password(new_password)
        user.save(update_fields=["password"])
        return Response({"detail": "Password reset successful."})


@api_view(['GET'])
@permission_classes([AllowAny])
def public_user_detail(request, user_id):
    try:
        user = User.objects.get(id=user_id)
        return Response({
            "id": user.id,
            "name": user.name,
            "email": user.email,
        })
    except User.DoesNotExist:
        return Response({"detail": "User not found"}, status=404)


# ---------------------------
# Login (wraps SimpleJWT's token view to observe outcomes)
# ---------------------------

class CustomTokenObtainPairView(TokenObtainPairView):
    """
    Same behavior as SimpleJWT's TokenObtainPairView — only difference
    is recording a login metric around the real logic, transparently.
    """
    def post(self, request, *args, **kwargs):
        try:
            response = super().post(request, *args, **kwargs)
        except Exception:
            user_logins_total.labels(result="failed").inc()
            raise
        user_logins_total.labels(result="success").inc()
        return response
