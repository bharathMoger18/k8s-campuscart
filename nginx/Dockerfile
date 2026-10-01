FROM nginx:alpine 

RUN rm /etc/nginx/conf.d/default.conf

COPY nginx/nginx.conf /etc/nginx/conf.d/campuscart.conf
COPY frontend /app/frontend

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]