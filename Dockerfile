FROM node:21-alpine AS base

# Install dependencies only when needed
FROM base AS deps
# Check https://github.com/nodejs/docker-node/tree/b4117f9333da4138b03a546ec926ef50a31506c3#nodealpine to understand why libc6-compat might be needed.
RUN apk add --no-cache libc6-compat \
        make \
        g++ \
        py3-pip \
        linux-headers
WORKDIR /app

# Install dependencies based on the preferred package manager
COPY package.json yarn.lock .yarnrc.yml ./
COPY packages/web/package.json ./packages/web/package.json
COPY packages/db/package.json ./packages/db/package.json
COPY packages/shared/package.json ./packages/shared/package.json
COPY packages/workers/package.json ./packages/workers/package.json
COPY packages/browser-extension/package.json ./packages/browser-extension/package.json
RUN corepack enable && \
        yarn install --immutable && \
        cd packages/web && \
        yarn install --immutable

################# The Web App ##############

# Rebuild the source code only when needed
FROM base AS web_builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY packages packages
COPY package.json yarn.lock .yarnrc.yml .

ENV NEXT_TELEMETRY_DISABLED 1

RUN cd packages/db && \
    yarn prisma generate

RUN corepack enable && \
    cd packages/web/ && \
    yarn next experimental-compile

FROM base AS web
WORKDIR /app

ENV NODE_ENV production
ENV NEXT_TELEMETRY_DISABLED 1

COPY --from=web_builder --chown=node:node /app/packages/web/.next/standalone ./
COPY --from=web_builder /app/packages/web/public ./packages/web/public

# Set the correct permission for prerender cache
RUN mkdir -p ./package/web/.next
RUN chown node:node ./packages/web/.next

# Automatically leverage output traces to reduce image size
# https://nextjs.org/docs/advanced-features/output-file-tracing
COPY --from=web_builder --chown=node:node /app/packages/web/.next/static ./packages/web/.next/static

WORKDIR /app/packages/web
USER root
EXPOSE 3000

ENV PORT 3000
# set hostname to localhost
ENV HOSTNAME "0.0.0.0"

# server.js is created by next build from the standalone output
# https://nextjs.org/docs/pages/api-reference/next-config-js/output
CMD ["node", "server.js"]


################# Db migrations ##############

FROM base AS db
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY packages packages
COPY package.json yarn.lock .yarnrc.yml .


RUN cd packages/db && \
    yarn prisma generate

WORKDIR /app/packages/db
USER root

CMD ["yarn", "prisma", "migrate", "deploy"]


################# The workers ##############

FROM base AS workers
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules

# Install chromium needed for puppeteer
RUN apk add --no-cache chromium runuser
ENV PUPPETEER_SKIP_DOWNLOAD true
ENV CHROME_PATH "/usr/bin/chromium-browser"
ENV BROWSER_EXECUTABLE_PATH "/app/start-chrome.sh"
ENV BROWSER_USER_DATA_DIR="/tmp/chrome"

RUN echo '#!/bin/sh' >> /app/start-chrome.sh && \
    echo 'set -x;' >> /app/start-chrome.sh && \
    echo 'id -u chrome &>/dev/null || adduser -S chrome' >> /app/start-chrome.sh && \
    echo 'mkdir -p /tmp/chrome && chown chrome /tmp/chrome' >> /app/start-chrome.sh && \
    echo 'runuser -u chrome -- $CHROME_PATH $@' >> /app/start-chrome.sh && \
    chmod +x /app/start-chrome.sh

COPY packages packages
COPY package.json yarn.lock .yarnrc.yml .

RUN cd packages/db && \
    yarn prisma generate

WORKDIR /app/packages/workers
USER root

CMD ["yarn", "run", "start:prod"]
