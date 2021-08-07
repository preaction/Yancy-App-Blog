# Yancy Blog App

This is an example community blog application built with Yancy.

## Run the App

To run the app locally, you must have Docker installed. Then to bring up
the app:

    make build up

The application will start on <http://127.0.0.1:3000>.

## Initial Setup

To set up the initial admin user account:

    docker-compose run web ./myapp.pl eval \
        'app->create_admin( q{admin}, q{<password>}, q{admin@example.com} )'

To enable Github authentication, create a `github.env` file with the
following information (from <https://github.com/settings/developers>):

    GITHUB_CLIENT_ID=...
    GITHUB_CLIENT_SECRET=...

## Run the Tests

To run the tests, you must have Docker installed. Then:

    make test

## Operations

* To connect to the database: `docker-compose exec db psql -U postgres`

