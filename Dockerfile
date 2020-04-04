FROM preaction/yancy:latest-pg

WORKDIR /app
COPY cpanfile /app
RUN cpanm --installdeps .

COPY /dist /dist
RUN [ -e /dist/* ] && cpanm /dist/* && rm -rf /dist || true

COPY . /app
