FROM nginx:alpine

# Copy health check HTML page
RUN mkdir -p /usr/share/nginx/html
RUN echo '<!DOCTYPE html><html><body><h1>Kamal Napper is Running!</h1></body></html>' > /usr/share/nginx/html/index.html
RUN echo '{"status":"ok","service":"kamal-napper"}' > /usr/share/nginx/html/health
RUN echo 'OK' > /usr/share/nginx/html/up

# Non-privileged user
RUN chown -R nginx:nginx /usr/share/nginx/html

# Health check configuration
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O- http://localhost/health || exit 1

EXPOSE 80

# Use nginx's default CMD