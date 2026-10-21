# Build context: the repository root (gateway loads ../../proto at runtime).
FROM node:22-alpine
WORKDIR /app
COPY services/gateway/package.json services/gateway/package-lock.json ./
RUN npm ci --omit=dev
COPY services/gateway/src ./src
COPY proto /proto
ENV PROTO_DIR=/proto
EXPOSE 3000
CMD ["node", "src/index.js"]
