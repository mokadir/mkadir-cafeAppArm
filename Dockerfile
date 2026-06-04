# =====================================================
# Stage 1: Generate the static HTML + gather all assets
# =====================================================
FROM python:3.12-slim AS builder

WORKDIR /app

# Copy the entire project context into the builder stage
# (generate.py, css/, js/, img/, video/, fontawesome/)
COPY . .

# Run the generator to produce index.html
RUN python generate.py

# =====================================================
# Stage 2: Serve the static site with Nginx
# =====================================================
FROM nginx:1.27-alpine

# Copy everything from the builder stage
COPY --from=builder /app/index.html        /usr/share/nginx/html/index.html
COPY --from=builder /app/css/              /usr/share/nginx/html/css/
COPY --from=builder /app/js/               /usr/share/nginx/html/js/
COPY --from=builder /app/img/              /usr/share/nginx/html/img/
COPY --from=builder /app/video/            /usr/share/nginx/html/video/
COPY --from=builder /app/fontawesome/      /usr/share/nginx/html/fontawesome/

# Expose port 80
EXPOSE 80

# Nginx runs in the foreground by default via its base image CMD
