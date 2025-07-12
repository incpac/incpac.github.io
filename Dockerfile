# Dockerfile
FROM ruby:3.1-alpine

# Install dependencies
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm

# Set working directory
WORKDIR /site

# Copy Gemfile and Gemfile.lock (if they exist)
COPY Gemfile* ./

# Install Jekyll and bundler
RUN gem install jekyll bundler

# Install dependencies if Gemfile exists, otherwise create basic setup
RUN if [ -f "Gemfile" ]; then \
        bundle install; \
    else \
        gem install github-pages; \
    fi

# Expose port 4000 (Jekyll default)
EXPOSE 4000

# Default command
CMD ["bundle", "exec", "jekyll", "serve", "--host", "0.0.0.0", "--livereload"]
