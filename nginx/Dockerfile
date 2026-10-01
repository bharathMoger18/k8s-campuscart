FROM nginx:alpine 

RUN rm /etc/nginx/conf.d/default.conf

# pid is only valid in nginx's main context, not inside a conf.d include —
# patch the base image's own nginx.conf to add it there.

COPY nginx/nginx.conf /etc/nginx/conf.d/campuscart.conf
COPY frontend /app/frontend

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]