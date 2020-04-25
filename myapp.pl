#!/usr/bin/env perl
use Mojolicious::Lite -signatures;
use Mojo::Pg;
use CommonMark;

helper pg => sub {
    state $pg = Mojo::Pg->new(
        sprintf 'postgres://postgres:%s@db/postgres', $ENV{POSTGRES_PASSWORD},
    );
};
app->pg->auto_migrate(1)->migrations->from_data;
plugin AutoReload =>;

plugin Moai => [ 'Bootstrap4', { version => '4.4.1' } ];
app->defaults({ layout => 'default' });

app->plugin( EPRenderer => {
    template => {
        # Enable modern Perl features in all templates
        prepend => <<~END,
            use v5.30;
            use experimental qw( signatures postderef );
            END
    },
} );

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
            'x-id-field' => 'username',
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
        blog_reactions => {
            'x-id-field' => 'blog_reaction_id',
            required => [qw( blog_post_id reaction_text )],
            properties => {
                blog_reaction_id => {
                    type => 'integer',
                    readOnly => 1,
                },
                blog_post_id => {
                    type => 'integer',
                    'x-foreign-key' => 'blog_posts',
                },
                reaction_text => {
                    type => 'string',
                },
                reaction_count => {
                    type => 'integer',
                },
            },
        },
        blog_comments => {
            'x-id-field' => 'blog_comment_id',
            required => [qw( blog_post_id username comment comment_html )],
            properties => {
                blog_comment_id => {
                    type => 'integer',
                    readOnly => 1,
                },
                blog_post_id => {
                    type => 'integer',
                    'x-foreign-key' => 'blog_posts',
                },
                username => {
                    type => 'string',
                    'x-foreign-key' => 'users',
                },
                comment => {
                    type => 'string',
                    format => 'markdown',
                    'x-html-field' => 'html',
                },
                comment_html => {
                    type => 'string',
                },
                created => {
                    type => 'string',
                    format => 'date-time',
                    default => 'now',
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
    before_render => [
        \&add_reactions,
        \&add_comments,
    ],
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

helper parse_markdown => sub( $c, $markdown, %opt ) {
    my $html = CommonMark->markdown_to_html( $markdown );
    my $dom = Mojo::DOM->new( $html );
    if ( $opt{nofollow} ) {
        $dom->find( 'a[href]' )->each( sub { $_->attr( rel => 'nofollow' ) } );
    }
    state @allow_tags = qw(
        a div span strong em b u i img table thead tfoot tbody tr td th figure
        figcaption aside pre code samp kbd p br hr q blockquote
    );
    $dom->find( sprintf ':not(%s)', join ',', @allow_tags )
        ->each( sub {
            $_->replace( '&lt;' . $_->tag . '&gt;' . $_->content . '&lt;/' . $_->tag . '&gt;' );
        } )
        ;
    return "$dom";
};

# Only allow certain reactions
my @ALLOW_REACTIONS = sort
    "\x{2764}\x{FE0F}",     # Red Heart
    "\x{1F602}",            # Face With Tears of Joy
    "\x{1F914}",            # Thinking Face
    "\x{1F92F}",            # Shocked Face with Exploding Head
    "\x{1F44F}",            # Clapping Hands Sign
    "\x{1F525}",            # Fire
    ;

sub add_reactions( $c, $item ) {
    my %react_counts =
        map $_->@{qw( reaction_text reaction_count )},
        $c->yancy->list(
            blog_reactions => {
                $item->%{qw( blog_post_id )},
            },
        );
    for my $icon ( @ALLOW_REACTIONS ) {
        push $item->{blog_reactions}->@*, {
            reaction_text => $icon,
            reaction_count => $react_counts{ $icon } // 0,
        };
    }
}

sub add_comments( $c, $item ) {
    $item->{blog_comments} = [
        $c->yancy->list(
            blog_comments => {
                $item->%{qw( blog_post_id )},
            },
            {
                order_by => 'created',
            },
        )
    ];
}

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
    before_render => [
        \&add_reactions,
        \&add_comments,
    ],
)->name( 'blog.list' );

$user_root->get( '/:blog_post_id/:slug' )->to(
    'yancy-multi_tenant#get',
    user_id_field => 'username',
    id_field => 'blog_post_id',
    schema => 'blog_posts',
    template => 'blog_get',
    before_render => [
        \&add_reactions,
        \&add_comments,
    ],
)->name( 'blog.get' );

$user_root->post( '/:blog_post_id/:slug/react' )->name( 'blog.react' )->to(
    'yancy#set',
    schema => 'blog_reactions',
    forward_to => 'blog.get',
    # XXX: Yancy should not need this since it is the x-id-field of
    # this schema
    id_field => 'blog_reaction_id',
    before_write => [
        sub( $c, $item ) {
            die sprintf 'Reaction %s not allowed', $item->{reaction_text}
                unless grep { $_ eq $item->{reaction_text} } @ALLOW_REACTIONS;
            # XXX: Yancy should be doing this automatically because it
            # is set in the URL...
            $item->{blog_post_id} = $c->param('blog_post_id');
            # Increment the counter
            my %search = (
                $c->stash->%{'blog_post_id'},
                $item->%{'reaction_text'},
            );
            if ( my ( $existing_item ) = $c->yancy->list( $c->stash->{schema}, \%search ) ) {
                $c->stash->{blog_reaction_id} = $existing_item->{ blog_reaction_id };
                $item->{reaction_count} = $existing_item->{ reaction_count } + 1;
            }
            else {
                $item->{reaction_count} = 1;
            }
        },
    ],
);

my $can_comment = app->yancy->auth->require_user;
$user_root->under( '/:blog_post_id/:slug/comment', $can_comment )->post( '' )->name( 'blog.comment' )->to(
    'yancy#set',
    schema => 'blog_comments',
    # XXX: Yancy should allow a subref here. forward_to doesn't work
    # because the comment gets created with a username that may be
    # different from the blog post
    #forward_to => 'blog.get',
    # XXX: Yancy should not need this since it is the x-id-field of
    # this schema
    id_field => 'blog_comment_id',
    before_write => [
        sub( $c, $item ) {
            $item->{username} = $c->login_user->{username};
            # XXX: Yancy should be doing this automatically because it
            # is set in the URL...
            $item->{blog_post_id} = $c->param('blog_post_id');
            # Parse comment Markdown
            $item->{comment_html} = $c->parse_markdown( $item->{comment}, nofollow => 1 );
            # XXX: Set up forwarding manually
            $c->redirect_to( 'blog.get' );
        },
    ],
);

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
    %= include '_blog_react', item => $blog
    %== $blog->{synopsis_html}
    <div class="border-top border-bottom border-light py-1 my-1 d-flex justify-content-between">
        %= link_to "Continue reading $blog->{title}", 'blog.get', $blog
        %= tag span => sprintf '%d comments', scalar $blog->{blog_comments}->@*
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

@@ _blog_react.html.ep
% my $item = stash 'item';
% my $_react_button = begin
    % my ( $text, $count ) = @_;
    %= tag button => ( name => 'reaction_text', value => $text, class => 'btn btn-outline-secondary' ), begin
        %= $count
        %= $text
    % end
% end
%= form_for 'blog.react', $item, begin
    %= csrf_field
    % for my $reaction ( $item->{blog_reactions}->@* ) {
        %= $_react_button->( $reaction->@{qw( reaction_text reaction_count )} )
    % }
% end

@@ blog_get.html.ep
% layout 'default';
% title $item->{title} . ' -- ' . $c->stash( 'username' );
<h1><%= $item->{title} %></h1>
%= include '_blog_react'
%== $item->{content_html}
<h2>Comments</h2>
% if ( login_user ) {
    %= form_for 'blog.comment', $item, ( class => 'mb-3' ) => begin
        %= csrf_field
        <div class="form-group">
            <label for="comment-text">Add Comment</label>
            %= text_area 'comment', ( id => 'comment-text', class => 'form-control' )
        </div>
        %= tag button => ( class => 'btn btn-primary' ), begin
            Submit Comment
        % end
    % end
% }
% else {
    Log in to comment
% }
% for my $comment ( $item->{blog_comments}->@* ) {
    <div class="card my-1">
        <h5 class="card-header d-flex justify-content-between">
            <span><%= $comment->{username} %></span>
            <span><%= $comment->{created} %></span>
        </h5>
        <div class="card-body">
            %== $comment->{comment_html}
        </div>
    </div>
% }

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
-- 5 up
CREATE TABLE blog_comments (
    blog_comment_id SERIAL PRIMARY KEY,
    blog_post_id INTEGER NOT NULL REFERENCES blog_posts( blog_post_id ),
    username TEXT NOT NULL REFERENCES users( username ),
    comment TEXT NOT NULL,
    comment_html TEXT NOT NULL,
    created TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
-- 5 down
DROP TABLE blog_comments;

-- 4 up
CREATE TABLE blog_reactions (
    blog_reaction_id SERIAL PRIMARY KEY,
    blog_post_id INTEGER NOT NULL REFERENCES blog_posts( blog_post_id ),
    reaction_text TEXT NOT NULL,
    reaction_count INTEGER DEFAULT 0
);
-- 4 down
DROP TABLE blog_reactions;

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
