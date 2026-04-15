FROM node:20-alpine

WORKDIR /app

RUN npm install -g json-server

COPY data/db.json /app/db.json

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:3000/products || exit 1

CMD ["json-server", "--host", "0.0.0.0", "--port", "3000", "db.json"]