FROM preaction/yancy:v1.047-pg

WORKDIR /app
COPY . /app
RUN cpanm --installdeps .
