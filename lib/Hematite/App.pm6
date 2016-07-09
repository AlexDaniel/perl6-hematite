use HTTP::Status;
use Hematite::Context;
use Hematite::Router;
use Hematite::Response;
use Hematite::Exceptions;

unit class Hematite::App is Hematite::Router;

has Callable %!error_handlers = ();
has Hematite::Route %!routes_by_name = ();
has Callable %!helpers = ();

submethod BUILD() {
    # default handler
    self.error-handler('unexpected', sub ($ctx, *%args) {
        my $ex = %args{'exception'};
        my $status = 500;

        $ctx.response.set-code($status);
        $ctx.response.field(Content-Type => 'text/plain');
        $ctx.response.content =
            sprintf("%s\n%s", get_http_status_msg($status), $ex.gist);

        # TODO: log it

        return;
    });

    # halt default handler
    self.error-handler('halt', sub ($ctx, *%args) {
        my $status  = %args{"status"};
        my %headers = %(%args{"headers"});
        my $body = %args{"body"} || get_http_status_msg($status);

        my $res = $ctx.response;

        # set status code
        $res.set-code($status);

        # set headers
        $res.field(|%headers);

        # set content
        $res.content = $body;
    });

    return self;
}

method plugin(Any:U $plugin, *%config) returns Hematite::App {
    $plugin.register(self, |%config);
    return self;
}

multi method helper(Str $name) {
    return %!helpers{$name};
}

multi method helper(Str $name, Callable $fn) returns Hematite::App {
    # TODO: give error if already exists
    %!helpers{$name} = $fn;
    return self;
}

method helpers() returns Hash {
    return %!helpers.clone;
}

multi method error-handler(Str $name) returns Callable {
    return %!error_handlers{$name};
}

multi method error-handler(Str $name, Callable $fn) {
    %!error_handlers{$name} = $fn;
    return self;
}

multi method error-handler() {
    return self.error-handler('unexpected');
}

multi method error-handler(Int $status) {
    return self.error-handler(~($status));
}

multi method error-handler(Callable $fn) {
    return self.error-handler('unexpected', $fn);
}

multi method error-handler(Int $status, Callable $fn) {
    return self.error-handler(~($status), $fn);
}

method get-route(Str $name) {
    return %!routes_by_name{$name};
}

method handler() returns Callable {
    my $app = self;

    # prepare routes
    my @routes = self._prepare-routes;
    for @routes -> $route {
        if ($route.name) {
            %!routes_by_name{$route.name} = $route;
        }
    }

    # prepare main middleware
    self.use(sub ($ctx) {
        for @routes -> $route {
            if ($route.match($ctx)) {
                $route($ctx);
                return;
            }
        }

        $ctx.not-found;
    });
    my $stack = self._prepare-middleware(self.middlewares);

    return sub ($env) {
        my $ctx = Hematite::Context.new($app, $env);

        try {
            # call middleware stack
            $stack($ctx);

            CATCH {
                my $ex = $_;

                default {
                    $ctx.handle-error('unexpected', exception => $ex);
                }
            }
        }

        # return context response
        my $status  = $ctx.response.code;
        my $headers = $ctx.response.header.hash;
        my $body    = $ctx.response.content;

        # set content-type charset if not present
        my $content_type = $headers{'Content-Type'}[0];
        if (!($content_type ~~ m/\s*charset\=/ )) {
            $headers{'Content-Type'} ~= '; charset=utf-8';
        }

        if (!$body.isa(Channel) && !$body.isa(IO::Handle)) {
            if (!$body.isa(Array)) {
                $body = Array.new($body.defined ?? $body !! "");
            }
        }

        return $status, $headers, $body;
    };
}

method _prepare-routes() returns Array {
    my @routes = self.routes;

    # sub-routers
    for self.groups.kv -> $pattern, $router {
        my @group_routes = $router._prepare-routes($pattern, []);
        @routes.append(@group_routes);
    }

    # sort routes
    @routes .= sort({ $^a.pattern cmp $^b.pattern });

    return @routes;
}
