FROM preaction/yancy:latest-pg

WORKDIR /app
COPY cpanfile /app
RUN cpanm --installdeps .

COPY . /app
