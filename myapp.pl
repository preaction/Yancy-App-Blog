#!/usr/bin/env perl
use Mojolicious::Lite -signatures;
use Mojo::Pg;

helper pg => sub {
    state $pg = Mojo::Pg->new(
        sprintf 'postgres://postgres:%s@db/postgres', $ENV{POSTGRES_PASSWORD},
    );
};
app->pg->auto_migrate(1)->migrations->from_data;
plugin AutoReload =>;

plugin Moai => [ 'Bootstrap4', { version => '4.4.1' } ];
app->defaults({ layout => 'default' });

plugin Yancy => {
    backend => { Pg => app->pg },
    read_schema => 1,
    editor => {
        require_user => {
            is_admin => 1,
        },
    },
    schema => {
        mojo_migrations => { 'x-hidden' => 1 },
        users => {
            title => 'Users',
            description => 'The user account information for authentication and authorization.',
            'x-list-columns' => [
                'username',
                'email',
                'is_admin',
            ],
            properties => {
                user_id => {
                    'x-hidden' => 1,
                },
                username => {
                    title => 'Username',
                    description => q{The user's name for login and display},
                },
                password => {
                    title => 'Password',
                    format => 'password',
                },
                email => {
                    title => 'E-mail',
                    format => 'email',
                },
                is_admin => {
                    title => 'Is Admin?',
                    description => q{If true, user is allowed to access the primary admin dashboard, edit users, and edit other users' blogs.},
                },
            },
        },
        blog_posts => {
            title => 'Blog Posts',
            description => <<~'END,',
                The posts in your blog.
                END,
            'x-list-columns' => [
                'title',
                'slug',
                'username',
                'published_date',
            ],
            'x-view-item-url' => '/user/{username}/{blog_post_id}/{slug}',
            properties => {
                blog_post_id => { 'x-hidden' => 1 },
                username => {
                    title => 'User',
                },
                title => {
                    title => 'Title',
                },
                slug => {
                    title => 'Slug',
                    description => 'The URL path part. Only lower-case letters, dashes, and underscores.',
                    pattern => '^[[:lower:]\-_]+$',
                },
                content => {
                    title => 'Content',
                    description => 'The main post content. Use Markdown for formatting.',
                    type => 'string',
                    format => 'markdown',
                    'x-html-field' => 'content_html',
                },
                content_html => { 'x-hidden' => 1 },
                synopsis => {
                    title => 'Synopsis',
                    description => 'The initial text on the main page. Use Markdown formatting.',
                    type => 'string',
                    format => 'markdown',
                    'x-html-field' => 'synopsis_html',
                },
                synopsis_html => { 'x-hidden' => 1 },
                published => {
                    title => 'Is Published?',
                },
                published_date => {
                    title => 'Published Date',
                    description => 'When the post should be published on the site.',
                },
            },
        },
    },
};

app->yancy->plugin( 'Auth', {
    schema => 'users',
    plugins => [
        [
            Password => {
                username_field => 'username',
                password_digest => {
                    type => 'Bcrypt',
                    cost => 12,
                    salt => $ENV{BCRYPT_SALT},
                },
            },
        ],
        # XXX: Add Github, Twitter, Auth0, etc...
    ],
} );

# User editor
app->yancy->plugin( 'Editor', {
    moniker => 'dashboard',
    backend => app->yancy->backend,
    schema => {
        blog_posts => {
            %{ app->yancy->schema( 'blog_posts' ) },
            'x-list-columns' => [qw( title slug published_date )],
            properties => {
                %{ app->yancy->schema( 'blog_posts' )->{properties} },
                username => { 'x-hidden' => 1 },
            },
        },
    },
    default_controller => 'Yancy::MultiTenant',
    require_user => { },
    route => app->routes->under( '/dashboard',
        sub( $c ) {
            # Needed by the MultiTenant controller
            if ( my $user = $c->login_user ) {
                $c->stash(
                    user_id => $user->{username},
                    user_id_field => 'username',
                );
            }
            return 1;
        },
    ),
} );

app->routes->get( '/' )->to(
    'yancy#list',
    schema => 'blog_posts',
    template => 'index',
    order_by => { -desc => 'published_date' },
)->name( 'index' );

helper login_user => sub { shift->yancy->auth->current_user };
helper create_user => sub( $c, $username, $password, $email, %opt ) {
    $c->yancy->create(
        users => {
            username => $username,
            password => $password,
            email => $email,
            %opt,
        },
    );
};
helper create_admin => sub( $c, $username, $password, $email, %opt ) {
    $c->create_user( $username, $password, $email, %opt );
};

my $user_root = app->routes->under( '/user/:username',
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
    order_by => { -desc => 'published_date' },
)->name( 'blog.list' );

$user_root->get( '/:blog_post_id/:slug' )->to(
    'yancy-multi_tenant#get',
    user_id_field => 'username',
    id_field => 'blog_post_id',
    schema => 'blog_posts',
    template => 'blog_get',
)->name( 'blog.get' );

get '/css/default' => { template => 'css/default', format => 'css' };
get '/about' => 'about';
get '/contact' => 'contact';

app->start;
__DATA__

@@ index.html.ep
% title 'Home - blogs.perl.org';
% for my $blog ( @$items ) {
    <article class="mb-3">
    <h1>
        %= link_to $blog->{title}, 'blog.get', $blog
        <small>by <%= link_to $blog->{username}, 'blog.list', $blog %></small>
    </h1>
    %== $blog->{synopsis_html}
    <div class="border-top border-bottom border-light py-1 my-1">
        %= link_to "Continue reading $blog->{title}", 'blog.get', $blog
    </div>
    </article>
% }
<div class="mt-3">
    %= include 'moai/pager'
</div>

@@ about.html.ep
% title 'About - blogs.perl.org';
<h1>About Blogs.perl.org</h1>
<p>This is a blog site for the Perl community.</p>

@@ contact.html.ep
% title 'Contact - blogs.perl.org';
<h1>Contact Us</h1>
<p>To report illegal or infringing content, e-mail us at: admin@example.com</p>

@@ _login.html.ep
% if ( login_user ) {
    %= tag div => ( class => 'd-flex flex-column' ), begin
        <span>Hello, <%= login_user->{username} %></span>
        %= link_to 'My Dashboard' => '/dashboard', ( class => 'btn btn-primary my-1' )
        % if ( login_user->{is_admin} ) {
            %= link_to 'Site Admin' => '/yancy', ( class => 'btn btn-outline-warning my-1' )
        % }
        %= link_to Logout => 'yancy.auth.logout', ( class => 'btn btn-outline-secondary my-1' )
    % end
% }
% else {
    %= $c->yancy->auth->login_form
% }

@@ blog_get.html.ep
% layout 'default';
% title $item->{title} . ' -- ' . $c->stash( 'username' );
<h1><%= $item->{title} %></h1>
%== $item->{content_html}

@@ css/default.css.ep
@import url(/css/flatly-bootstrap.min.css);
@import url(/css/darkly-bootstrap.min.css) (prefers-color-scheme: dark);
/* TODO: Let the user specify they want dark mode in a cookie */

:root {
    /* Tell browsers we support light/dark preferences */
    color-schema: light dark;
}

/* Fix some things about darkly on dark mode */
@media ( prefers-color-scheme: dark ) {
    .form-control, .form-control:focus {
        background-color: #303030;
        color: #fff;
    }
    .form-control:focus {
        background-color: #444;
    }
}

@@ layouts/default.html.ep
% extends 'layouts/moai/default';
% content_for head => begin
    %= stylesheet '/css/default.css'
    %= stylesheet '/yancy/font-awesome/css/font-awesome.css'
% end
% content_for navbar => begin
    <%= include 'moai/menu/navbar',
        class => {
            navbar => 'bg-primary navbar-dark',
        },
        brand => [ 'Blogs.perl.org' => 'index' ],
        menu => [
            [ Home => 'index' ],
            [ 'About' => 'about' ],
            [ 'Contact' => 'contact' ],
        ],
    %>
% end
% content_for sidebar => begin
    %= include '_login'
    <!-- XXX: Add recent activity -->
% end

@@ migrations
-- 3 up
ALTER TABLE blog_posts RENAME COLUMN publish_date TO published_date;
-- 3 down
ALTER TABLE blog_posts RENAME COLUMN published_date TO publish_date;

-- 2 up
ALTER TABLE users ADD COLUMN is_admin BOOLEAN DEFAULT FALSE;
-- 2 down
ALTER TABLE users DROP COLUMN is_admin;

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
