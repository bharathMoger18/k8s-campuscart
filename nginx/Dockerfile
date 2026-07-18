FROM nginx:alpine 

RUN rm /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/conf.d/campuscart.conf

EXPOSE 8090

CMD ["nginx", "-g", "daemon off;"]
