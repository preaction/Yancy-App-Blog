#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::Pg;

helper pg => sub {
    state $pg = Mojo::Pg->new(
        sprintf 'postgres://postgres:%s@db/postgres', $ENV{POSTGRES_PASSWORD},
    );
};
app->pg->auto_migrate(1)->migrations->from_data;

plugin Yancy => {
    backend => { Pg => app->pg },
    read_schema => 1,
    schema => {
        mojo_migrations => { 'x-hidden' => 1 },
        blog_posts => {
            properties => {
                content => {
                    type => 'string',
                    format => 'markdown',
                    'x-html-field' => 'content_html',
                },
                content_html => { 'x-hidden' => 1 },
                synopsis => {
                    type => 'string',
                    format => 'markdown',
                    'x-html-field' => 'synopsis_html',
                },
                synopsis_html => { 'x-hidden' => 1 },
            },
        },
    },
};

app->yancy->plugin( 'Auth::Password', {
    schema => 'users',
    username_field => 'username',
    password_digest => {
        type => 'Bcrypt',
        cost => 12,
        salt => $ENV{BCRYPT_SALT},
    },
} );

# User editor
app->yancy->plugin( 'Editor', {
    controller_class => 'Yancy::MultiTenant',
    require_user => 1,
} );

app->routes->get( '/' )->to(
    'yancy#list',
    schema => 'blog_posts',
    template => 'index',
    order_by => { -desc => 'publish_date' },
)->name( 'index' );

helper login_user => sub { shift->yancy->auth->current_user };

my $user_root = app->routes->under( '/:username',
    sub {
        my ( $c ) = @_;
        my $username = $c->stash( 'username' );
        return $c->reply->not_found if !$c->yancy->get( users => $username );
        $c->stash( user_id => $username );
        return 1;
    },
);

$user_root->get( '' )->to(
    'yancy-multi_tenant#list',
    user_id_field => 'username',
    schema => 'blog_posts',
    template => 'index',
    order_by => { -desc => 'publish_date' },
)->name( 'blog.list' );

$user_root->get( '/:blog_post_id/:slug' )->to(
    'yancy-multi_tenant#get',
    user_id_field => 'username',
    id_field => 'blog_post_id',
    schema => 'blog_posts',
    template => 'blog_get',
)->name( 'blog.get' );

app->start;
__DATA__

@@ index.html.ep
% layout 'default';
% title 'blogs.perl.org';
%= include 'el/login'
<h1>Blogs.Perl.Org</h1>
% for my $blog ( @$items ) {
    <h2>
        %= link_to $blog->{title}, 'blog.get', $blog
    </h2>
    %== $blog->{synopsis_html}
    %= link_to "Read $blog->{title}", 'blog.get', $blog
% }

@@ el/login.html.ep
% if ( login_user ) {
    Hello, <%= login_user->{username} %> <%= link_to Logout => 'yancy.auth.password.logout' %>
% }
% else {
    %= form_for 'yancy.auth.password.login' => begin
        %= text_field username => ( placeholder => 'user' )
        %= password_field password =>
        %= tag button => begin
            Login
        % end
    % end
% }

@@ blog_get.html.ep
% layout 'default';
% title $item->{title} . ' -- ' . $c->stash( 'username' );
<h1><%= $item->{title} %></h1>
%== $item->{content_html}

@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head><title><%= title %></title></head>
  <body><%= content %></body>
</html>

@@ migrations
-- 1 up
CREATE TABLE users (
    user_id SERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    email TEXT NOT NULL
);
CREATE TABLE blog_posts (
    blog_post_id SERIAL PRIMARY KEY,
    username TEXT NOT NULL REFERENCES users( username ),
    title TEXT NOT NULL,
    slug TEXT NOT NULL,
    content TEXT NOT NULL,
    content_html TEXT NOT NULL,
    synopsis TEXT NOT NULL,
    synopsis_html TEXT NOT NULL,
    published BOOLEAN DEFAULT 't',
    publish_date TIMESTAMP NOT NULL DEFAULT NOW()
);

-- 1 down
DROP TABLE users;
DROP TABLE blogs;
