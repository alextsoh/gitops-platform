FROM node:25-slim AS base

ENV NODE_ENV=production

WORKDIR /usr/src/app

COPY package*.json ./

# Use cache mount to speed up install of existing dependencies
RUN --mount=type=cache,target=/usr/src/app/.npm \
  npm set cache /usr/src/app/.npm && \
  npm ci --only=production

USER node

# Copy remaining source code AFTER installing dependencies. 
COPY --chown=node:node ./src/ .

EXPOSE 3000

CMD [ "node", "index.js" ]
