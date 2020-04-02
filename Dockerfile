FROM preaction/yancy:v1.047-pg

WORKDIR /app
COPY cpanfile /app
RUN cpanm --installdeps .

COPY . /app
