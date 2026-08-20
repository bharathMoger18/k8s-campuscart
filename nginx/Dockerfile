FROM nginx:alpine 

RUN rm /etc/nginx/conf.d/default.conf

COPY nginx/nginx.conf /etc/nginx/conf.d/campuscart.conf
COPY frontend /app/frontend

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]