
FROM nginx:1.27-alpine

LABEL org.opencontainers.image.title="Industrial Predictive Maintenance Dashboard"
LABEL org.opencontainers.image.description="Equipment monitoring and predictive maintenance demo"

ARG HTML_FILE=index.html
COPY ${HTML_FILE} /usr/share/nginx/html/index.html

EXPOSE 80

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1
