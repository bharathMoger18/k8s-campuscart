# chat/views.py
from rest_framework import viewsets, permissions, status
from rest_framework.response import Response
from .models import Conversation, Message
from .serializers import ConversationSerializer, MessageSerializer
from products.models import Product

class ConversationViewSet(viewsets.ModelViewSet):
    queryset = Conversation.objects.all()
    serializer_class = ConversationSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        return Conversation.objects.filter(participants=self.request.user)

    def create(self, request, *args, **kwargs):
        product_id = request.data.get("product")
        other_user_id = request.data.get("other_user")

        if not (product_id and other_user_id):
            return Response({"error": "product and other_user required"}, status=400)

        product = Product.objects.filter(id=product_id).first()
        if not product:
            return Response({"error": "Invalid product"}, status=400)

        # Match an EXISTING conversation only if it's for this product AND
        # has both of these exact participants — matching on product alone
        # would merge different buyers' private conversations about the
        # same product into one shared thread.
        conversation = (
            Conversation.objects.filter(product=product, participants=request.user.id)
            .filter(participants=other_user_id)
            .first()
        )
        if not conversation:
            conversation = Conversation.objects.create(product=product)
            conversation.participants.add(request.user.id, other_user_id)

        serializer = self.get_serializer(conversation)
        return Response(serializer.data, status=201)


class MessageViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class = MessageSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        conv_id = self.kwargs.get("conversation_id")
        # Only return messages if the requesting user is actually a
        # participant of this conversation — otherwise any authenticated
        # user could read any conversation's messages just by guessing
        # or incrementing the conversation ID in the URL.
        return Message.objects.filter(
            conversation_id=conv_id,
            conversation__participants=self.request.user,
        )