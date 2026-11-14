FROM nginx:alpine 
LABEL org.opencontainers.image.source="https://github.com/bharathMoger18/k8s-campuscart"

RUN apk upgrade --no-cache

RUN chown -R nginx:nginx /var/cache/nginx /var/log/nginx /etc/nginx /run
RUN rm /etc/nginx/conf.d/default.conf


COPY nginx/nginx.conf /etc/nginx/conf.d/campuscart.conf
COPY frontend /app/frontend

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]