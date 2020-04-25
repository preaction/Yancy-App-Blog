FROM preaction/yancy:latest-pg

RUN apt-get update && apt-get install -y \
    libcmark-dev \
    libssl-dev

WORKDIR /app
COPY cpanfile /app
RUN cpanm --installdeps .

COPY /dist /dist
RUN [ -e /dist/* ] && cpanm /dist/* && rm -rf /dist || true

COPY . /app
