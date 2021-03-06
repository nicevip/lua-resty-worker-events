# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 6 - 9);

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_socket_log_errors off;
    lua_package_path "$pwd/lib/?.lua;;";
_EOC_

#no_diff();
no_long_string();
master_on();
run_tests();

__DATA__



=== TEST 1: worker.events starting and stopping, with its own events
--- SKIP
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", data)
            end)
    local ok, err = we.configure{
        shm = "worker_events",
        interval = 0.001,
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.print("hello world\\n")
            local f = assert(io.open("t/servroot/logs/nginx.pid"))
            local pid = assert(tonumber(f:read()), "read pid")
            f:close()
            assert(os.execute("kill -HUP "..pid))
        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*|gracefully .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
gracefully shutting down
worker-events: handling event; source=resty-worker-events, event=stopping, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=stopping, pid=\d+, data=nil
worker-events: handling event; source=resty-worker-events, event=stopping, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=stopping, pid=\d+, data=nil$/
--- timeout: 6
--- wait: 0.2



=== TEST 2: worker.events posting and handling events, broadcast and local
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", data)
            end)
    local ok, err = we.configure{
        shm = "worker_events",
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            we.post_local("content_by_lua","request2","01234567890")
            we.post("content_by_lua","request3","01234567890")
            ngx.print("hello world\\n")

        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request2, pid=nil
worker-events: handler event;  source=content_by_lua, event=request2, pid=nil, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890$/
--- timeout: 6



=== TEST 3: worker.events handling remote events
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", tostring(data))
            end)
    local ok, err = we.configure{
        shm = "worker_events",
    }

    local cjson = require("cjson.safe").new()

    local event_id = assert(ngx.shared.worker_events:incr("events-last", 1))
    assert(ngx.shared.worker_events:add("events-data:"..tostring(event_id),
        cjson.encode({ source="hello", event="1", data="there-1", pid=123456}), 2))

    local event_id = assert(ngx.shared.worker_events:incr("events-last", 1))
    assert(ngx.shared.worker_events:add("events-data:"..tostring(event_id),
        cjson.encode({ source="hello", event="2", data="there-2", pid=123456}), 2))

    local event_id = assert(ngx.shared.worker_events:incr("events-last", 1))
    assert(ngx.shared.worker_events:add("events-data:"..tostring(event_id),
        cjson.encode({ source="hello", event="3", data="there-3", pid=123456}), 2))

    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local cjson = require("cjson.safe").new()
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            we.post_local("content_by_lua","request2","01234567890")

            local event_id = assert(ngx.shared.worker_events:incr("events-last", 1))
            assert(ngx.shared.worker_events:add("events-data:"..tostring(event_id),
                  cjson.encode({ source="hello", event="4", data="there-4", pid=123456}), 2))

            we.post("content_by_lua","request3","01234567890")
            ngx.print("hello world\\n")

        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=hello, event=1, pid=123456
worker-events: handler event;  source=hello, event=1, pid=123456, data=there-1
worker-events: handling event; source=hello, event=2, pid=123456
worker-events: handler event;  source=hello, event=2, pid=123456, data=there-2
worker-events: handling event; source=hello, event=3, pid=123456
worker-events: handler event;  source=hello, event=3, pid=123456, data=there-3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request2, pid=nil
worker-events: handler event;  source=content_by_lua, event=request2, pid=nil, data=01234567890
worker-events: handling event; source=hello, event=4, pid=123456
worker-events: handler event;  source=hello, event=4, pid=123456, data=there-4
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890$/
--- timeout: 6



=== TEST 4: worker.events missing data, timeout
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", tostring(data))
            end)
    local ok, err = we.configure{
        shm = "worker_events",
        interval = 1,
        timeout = 2,
        wait_max = 0.5,
        wait_interval = 0.200,
    }

    local cjson = require("cjson.safe").new()

    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local cjson = require("cjson.safe").new()
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            we.post("content_by_lua","request2","01234567890", true)

            local event_id = assert(ngx.shared.worker_events:incr("events-last", 1))

            we.post("content_by_lua","request3","01234567890")
            ngx.print("hello world\\n")

        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[alert]
--- grep_error_log eval: qr/worker-events: .*|worker-events: dropping event; waiting for event data timed out.*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=01234567890
worker-events: dropping event; waiting for event data timed out, id: 4.*
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890$/
--- timeout: 6



=== TEST 5: worker.events 'one' being done, and only once
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", data)
            end)
    local ok, err = we.configure{
        timeout = 0.4,
        shm = "worker_events",
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            we.post("content_by_lua","request2","01234567890", "unique_value")
            we.post("content_by_lua","request3","01234567890", "unique_value")
            ngx.sleep(0.5) -- wait for unique timeout to expire
            we.post("content_by_lua","request4","01234567890", "unique_value")
            we.post("content_by_lua","request5","01234567890", "unique_value")
            we.post("content_by_lua","request6","01234567890")
            ngx.print("hello world\\n")

        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*?, pid=.*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request4, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request4, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request6, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request6, pid=\d+, data=01234567890$/
--- timeout: 6



=== TEST 6: worker.events 'unique' being done by another worker
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", data)
            end)
    local ok, err = we.configure{
        shm = "worker_events",
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            assert(ngx.shared.worker_events:add("events-one:unique_value", 666))
            we.post("content_by_lua","request2","01234567890", "unique_value")
            we.post("content_by_lua","request3","01234567890")
            ngx.print("hello world\\n")
        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*?, pid=.*|worker-events: skipping event \d+ was handled by worker \d+/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: skipping event 3 was handled by worker 666
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890$/
--- timeout: 6



=== TEST 7: registering and unregistering event handlers at different levels
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    local cb = function(extra, data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", data, ", callback=",extra)
    end
    ngx.cb_global  = function(...) return cb("global", ...) end
    ngx.cb_source  = function(...) return cb("source", ...) end
    ngx.cb_event12 = function(...) return cb("event12", ...) end
    ngx.cb_event3  = function(...) return cb("event3", ...) end

    we.register(ngx.cb_global)
    we.register(ngx.cb_source,  "content_by_lua")
    we.register(ngx.cb_event12, "content_by_lua", "request1", "request2")
    we.register(ngx.cb_event3,  "content_by_lua", "request3")

    local ok, err = we.configure{
        shm = "worker_events",
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","123")
            we.post("content_by_lua","request2","123")
            we.post("content_by_lua","request3","123")
            we.unregister(ngx.cb_global)
            we.post("content_by_lua","request1","124")
            we.post("content_by_lua","request2","124")
            we.post("content_by_lua","request3","124")
            we.unregister(ngx.cb_source,  "content_by_lua")
            we.post("content_by_lua","request1","125")
            we.post("content_by_lua","request2","125")
            we.post("content_by_lua","request3","125")
            we.unregister(ngx.cb_event12, "content_by_lua", "request1", "request2")
            we.post("content_by_lua","request1","126")
            we.post("content_by_lua","request2","126")
            we.post("content_by_lua","request3","126")
            we.unregister(ngx.cb_event3,  "content_by_lua", "request3")
            we.post("content_by_lua","request1","127")
            we.post("content_by_lua","request2","127")
            we.post("content_by_lua","request3","127")
            ngx.print("hello world\\n")

        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil, callback=global
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=123, callback=global
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=123, callback=source
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=123, callback=event12
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=123, callback=global
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=123, callback=source
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=123, callback=event12
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=123, callback=global
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=123, callback=source
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=123, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=124, callback=source
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=124, callback=event12
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=124, callback=source
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=124, callback=event12
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=124, callback=source
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=124, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=125, callback=event12
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=125, callback=event12
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=125, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=126, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+$/
--- timeout: 6



=== TEST 8: registering and GC'ing weak event handlers at different levels
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.shared.worker_events:flush_all()
            local we = require "resty.worker.events"
            local ok, err = we.configure{
                shm = "worker_events",
            }
            ngx.sleep(1)

            local count = 0

            local cb = {
              global = function(source, event)
                ngx.log(ngx.DEBUG, "global handler: ", source, ", ", event)
                count = count + 1
              end,
              source = function(source, event)
                ngx.log(ngx.DEBUG, "global source: ", source, ", ", event)
                count = count + 1
              end,
              event12 = function(source, event)
                ngx.log(ngx.DEBUG, "global event12: ", source, ", ", event)
                count = count + 1
              end,
              event3 = function(source, event)
                ngx.log(ngx.DEBUG, "global event3: ", source, ", ", event)
                count = count + 1
              end,
            }
            we.register_weak(cb.global)
            we.register_weak(cb.source,  "content_by_lua")
            we.register_weak(cb.event12, "content_by_lua", "request1", "request2")
            we.register_weak(cb.event3,  "content_by_lua", "request3")

            we.post("content_by_lua","request1","123")
            we.post("content_by_lua","request2","123")
            we.post("content_by_lua","request3","123")
            ngx.say("before GC:", count)

            cb = nil
            collectgarbage()
            collectgarbage()
            count = 0

            we.post("content_by_lua","request1","123")
            we.post("content_by_lua","request2","123")
            we.post("content_by_lua","request3","123")
            ngx.say("after GC:", count) -- 0

        ';
    }

--- request
GET /t
--- response_body
before GC:9
after GC:0
--- no_error_log
--- timeout: 6



=== TEST 9: callback error handling
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.shared.worker_events:flush_all()
            local we = require "resty.worker.events"
            local ok, err = we.configure{
                shm = "worker_events",
            }
            local error_func = function()
              error("something went wrong here!")
            end
            local test_callback = function(source, event, data, pid)
              error_func() -- nested call to check stack trace
            end
            we.register(test_callback)

            -- non-serializable test data containing a function value
            -- use "nil" as data, reproducing issue #5
            we.post("content_by_lua","test_event", nil)

            ngx.say("ok")
        ';
    }

--- request
GET /t
--- response_body
ok
--- error_log
something went wrong here!



=== TEST 10: callback error stacktrace
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.shared.worker_events:flush_all()
            local we = require "resty.worker.events"
            local ok, err = we.configure{
                shm = "worker_events",
            }

            local error_func = function()
              error("something went wrong here!")
            end
            local in_between = function()
              error_func() -- nested call to check stack trace
            end
            local test_callback = function(source, event, data, pid)
              in_between() -- nested call to check stack trace
            end

            we.register(test_callback)
            we.post("content_by_lua","test_event")

            ngx.say("ok")
        ';
    }

--- request
GET /t
--- response_body
ok
--- error_log
something went wrong here!
in function 'error_func'
in function 'in_between'



=== TEST 11: shm fragmentation
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.shared.worker_events:flush_all()
            local we = require "resty.worker.events"
            local ok, err = we.configure{
                shm = "worker_events",
                shm_retries = 999,
            }

            -- fill the shm
            for i = 1, 1500000 do
                ngx.shared.worker_events:add(i, tostring(i))
            end

            local ok, err = we.post("source", "event", ("y"):rep(1024):rep(500))
            ngx.say(ok or err)
        ';
    }

--- request
GET /t
--- response_body
done
