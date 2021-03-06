gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local json = require "json"

local font = resource.load_font "roboto.ttf"
local black = resource.create_colored_texture(0,0,0,1)

local shaders = {
    multisample = resource.create_shader[[
        uniform sampler2D Texture;
        varying vec2 TexCoord;
        uniform vec4 Color;
        uniform float x, y, s;
        void main() {
            vec2 texcoord = TexCoord * vec2(s, s) + vec2(x, y);
            vec4 c1 = texture2D(Texture, texcoord);
            vec4 c2 = texture2D(Texture, texcoord + vec2(0.0002, 0.0002));
            gl_FragColor = (c2+c1)*0.5 * Color;
        }
    ]], 
    simple = resource.create_shader[[
        uniform sampler2D Texture;
        varying vec2 TexCoord;
        uniform vec4 Color;
        uniform float x, y, s;
        void main() {
            gl_FragColor = texture2D(Texture, TexCoord * vec2(s, s) + vec2(x, y)) * Color;
        }
    ]], 
}

local settings = {
    IMAGE_PRELOAD = 2;
    PRELOAD_TIME = 5;
}

local function ramp(t_s, t_e, t_c, ramp_time)
    if ramp_time == 0 then return 1 end
    local delta_s = t_c - t_s
    local delta_e = t_e - t_c
    return math.min(1, delta_s * 1/ramp_time, delta_e * 1/ramp_time)
end

local function cycled(items, offset)
    offset = offset % #items + 1
    return items[offset], offset
end

local Loading = (function()
    local font = resource.load_font "roboto.ttf"

    local loading = "Loading..."
    local size = 80
    local w = font:width(loading, size)
    local alpha = 0
    
    local function draw()
        if alpha == 0 then
            return
        end
        font:write((WIDTH-w)/2, (HEIGHT-size)/2, loading, size, 1,1,1,alpha)
    end

    local function fade_in()
        alpha = math.min(1, alpha + 0.01)
    end

    local function fade_out()
        alpha = math.max(0, alpha - 0.01)
    end

    return {
        fade_in = fade_in;
        fade_out = fade_out;
        draw = draw;
    }
end)()

local Config = (function()
    local playlist = {}
    local switch_time = 1
    local kenburns = false
    local switch_time = 30

    util.file_watch("config.json", function(raw)
        print "updated config.json"
        local config = json.decode(raw)

        kenburns = config.kenburns
        switch_time = config.switch_time
        display_time = config.display_time
    end)

    local photos = {}

    local function update_playlist()
        print "updating playlist"
        local sorted = {}
        for basename, photo in pairs(photos) do
            sorted[#sorted+1] = photo
        end
        table.sort(sorted, function(p1, p2)
            return p1.stored < p2.stored
        end)

        playlist = {}
        for idx = 1, #sorted do
            local photo = sorted[idx]
            playlist[#playlist+1] = {
                asset_name = photo['jpg'];
                type = "image";
                meta = photo;
            }
        end

        node.gc()
    end

    node.event("content_update", function(filename) 
        print("updated content", filename)
        if filename:sub(1, 6) == "photo-" and filename:sub(-4, -1) == ".jpg" then
            local basename = filename:sub(1, -5)
            photos[basename] = json.decode(resource.load_file(basename .. ".json"))
            update_playlist()
        end
    end)

    node.event("content_remove", function(filename)
        if filename:sub(1, 6) == "photo-" and filename:sub(-4, -1) == ".jpg" then
            local basename = filename:sub(1, -5)
            photos[basename] = nil
            update_playlist()
        end
    end)

    return {
        get_playlist = function() return playlist end;
        get_switch_time = function() return switch_time end;
        get_display_time = function() return display_time end;
        get_kenburns = function() return kenburns end;
    }
end)()

local Scheduler = (function()
    local playlist_offset = 0

    local function get_next()
        local playlist = Config.get_playlist()
        if #playlist == 0 then
            print "no item to schedule"
            return nil
        end

        local item
        item, playlist_offset = cycled(playlist, playlist_offset)
        print(string.format("next scheduled item is %s", item.asset_name))
        return item
    end

    return {
        get_next = get_next;
    }
end)()

local ImageJob = function(item, ctx, fn)
    fn.wait_t(ctx.starts - settings.IMAGE_PRELOAD)

    local res = resource.load_image{
        file = ctx.asset,
        mipmap = true,
    }

    for now in fn.wait_next_frame do
        local state, err = res:state()
        if state == "loaded" then
            break
        elseif state == "error" then
            error("preloading failed: " .. err)
        end
    end

    print "waiting for start"
    local starts = fn.wait_t(ctx.starts)
    local duration = ctx.ends - starts
    print "starting"

    if Config.get_kenburns() then
        local function lerp(s, e, t)
            return s + t * (e-s)
        end

        local paths = {
            {from = {x=0.0,  y=0.0,  s=1.0 }, to = {x=0.08, y=0.08, s=0.9 }},
            {from = {x=0.05, y=0.0,  s=0.93}, to = {x=0.03, y=0.03, s=0.97}},
            {from = {x=0.02, y=0.05, s=0.91}, to = {x=0.01, y=0.05, s=0.95}},
            {from = {x=0.07, y=0.05, s=0.91}, to = {x=0.04, y=0.03, s=0.95}},
        }

        local path = paths[math.random(1, #paths)]

        local to, from = path.to, path.from
        if math.random() >= 0.5 then
            to, from = from, to
        end

        local w, h = res:size()
        local multisample = w / WIDTH > 0.8 or h / HEIGHT > 0.8
        local shader = multisample and shaders.multisample or shaders.simple
        
        for now in fn.wait_next_frame do
            local t = (now - starts) / duration
            shader:use{
                x = lerp(from.x, to.x, t);
                y = lerp(from.y, to.y, t);
                s = lerp(from.s, to.s, t);
            }
            util.draw_correct(res, 0, 0, WIDTH, HEIGHT, ramp(
                ctx.starts, ctx.ends, now, Config.get_switch_time()
            ))
            shader:deactivate()
            if now > ctx.ends then
                break
            end
        end
    else
        for now in fn.wait_next_frame do
            util.draw_correct(res, 0, 0, WIDTH, HEIGHT, ramp(
                ctx.starts, ctx.ends, now, Config.get_switch_time()
            ))
            if now > ctx.ends then
                break
            end
        end
    end

    res:dispose()
    print "image job completed"
    return true
end

local Queue = (function()
    local jobs = {}
    local scheduled_until = sys.now()

    local function enqueue(starts, ends, item)
        local co = coroutine.create(({
            image = ImageJob,
        })[item.type])

        local success, asset = pcall(resource.open_file, item.asset_name)
        if not success then
            print("CANNOT GRAB ASSET: ", asset)
            return
        end

        -- an image may overlap another image
        if #jobs > 0 and jobs[#jobs].type == "image" and item.type == "image" then
            starts = starts - Config.get_switch_time()
        end

        local ctx = {
            starts = starts,
            ends = ends,
            asset = asset;
        }

        local success, err = coroutine.resume(co, item, ctx, {
            wait_next_frame = function ()
                return coroutine.yield(false)
            end;
            wait_t = function(t)
                while true do
                    local now = coroutine.yield(false)
                    if now >= t then
                        return now
                    end
                end
            end;
        })

        if not success then
            print("CANNOT START JOB: ", err)
            return
        end

        jobs[#jobs+1] = {
            co = co;
            ctx = ctx;
            type = item.type;
        }

        scheduled_until = ends
        print("added job. scheduled program until ", scheduled_until)
    end

    local function tick()
        gl.clear(0, 0, 0, 0)

        for try = 1,3 do
            if sys.now() + settings.PRELOAD_TIME < scheduled_until then
                break
            end
            local item = Scheduler.get_next()
            if item then
                enqueue(scheduled_until, scheduled_until + Config.get_display_time(), item)
            end
        end

        if #jobs == 0 then
            Loading.fade_in()
        else
            Loading.fade_out()
        end

        local now = sys.now()
        for idx = #jobs,1,-1 do -- iterate backwards so we can remove finished jobs
            local job = jobs[idx]
            local success, is_finished = coroutine.resume(job.co, now)
            if not success then
                print("CANNOT RESUME JOB: ", is_finished)
                table.remove(jobs, idx)
            elseif is_finished then
                table.remove(jobs, idx)
            end
        end

        Loading.draw()
    end

    return {
        tick = tick;
    }
end)()

util.set_interval(1, node.gc)

function node.render()
    gl.clear(0, 0, 0, 1)
    Queue.tick()
end
