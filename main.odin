package main

import "core:fmt"
import "core:math"
import "core:strings"
import os "core:os/os2"
import fp "core:path/filepath"
import rl "vendor:raylib"
import "rulti"

import "core:sys/windows"

Vector :: [2] f32

font      : rl.Font
mono_font : rl.Font

HELP :: 
    "  : padėti skaičių     u : undo (padėtą skaičių)    + : padidinti skaičių \n" +
    "  : slankioti ekrane   r : redo                     - : sumažinti skaičių \n" +
    "  : zoom in/out        s : save („n“ + praeitas failo pavadinimas)"

Numbering :: struct {
    number : string,
    pos    : Vector,
}

number  : int = 1
numbers : [dynamic] Numbering
undoes  : [dynamic] Numbering

the_file : string
the_tex  : rl.Texture

File :: struct { path: string, t: rl.Texture, pos, size: Vector }
files : [dynamic] File

window: struct {
    size        : Vector,
    mouse       : Vector, // raw mouse pos
    cursor      : Vector, // mouse |> camera
    camera      : rl.Camera2D, 
    camera_vel  : Vector,

    current_img : int,

    saving_anim : f32,
    saved_index : int,
    save_state  : enum { None, Render, Save },
    rt          : rl.RenderTexture2D,
}

back :: proc(list: [dynamic] $T) -> T {
    if len(list) > 0 { return list[len(list) - 1] }
    return {}
}

intersects :: proc(a, b, bs: Vector) -> bool {
    return rl.CheckCollisionPointRec(a, { b.x, b.y, bs.x, bs.y })
}

load_icon :: proc(data: [] byte) -> rl.Texture {
    tex := rl.LoadTextureFromImage(rl.LoadImageFromMemory(".png", raw_data(data), cast(i32) len(data)))
    rl.SetTextureFilter(tex, .BILINEAR)
    return tex 
}

// windows is the operating system of all time...
load_tex_windows :: proc(path: string) -> rl.Texture2D {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return {} }
	return 	rl.LoadTextureFromImage(rl.LoadImageFromMemory(strings.clone_to_cstring(fp.ext(path), context.temp_allocator), raw_data(data), i32(len(data))))
}

// useless, cause you can actually just set the chcp 65001 and I forgot...
// I guess, at least, I was able forget :)
save_img_windows :: proc(image: rl.Image, path: string) {
	size :  i32
	data := rl.ExportImageToMemory(image, strings.clone_to_cstring(fp.ext(path)), &size)
	err := os.write_entire_file(path, ([^]byte)(data)[:size])
	assert(err == nil)
}

main :: proc() {

	when ODIN_OS == .Windows {
		windows.SetConsoleOutputCP(.UTF8)
	}

    rl.SetTraceLogLevel(.ERROR)
    rl.SetConfigFlags({ .WINDOW_RESIZABLE })
    rl.InitWindow(1280, 720, "Sekų diagramų numeravimas")
    rl.SetTargetFPS(60)
    
    font = rulti.LoadFontFromMemory(#load("Helvetica.ttf"), 12)
    mono_font = rulti.LoadFontFromMemory(#load("hack.ttf"), 32)

    rl.SetTextureFilter(font.texture, .POINT) // Lol

    icons := [?] [] byte {
        #load("mouse0.png"),
        #load("mouse1.png"),
        #load("mouse2.png"),
    }

    mouse0_icon := load_icon(icons[0])
    mouse1_icon := load_icon(icons[1])
    mouse2_icon := load_icon(icons[2])

    rulti.DEFAULT_TEXT_OPTIONS.font  = font
    rulti.DEFAULT_TEXT_OPTIONS.color = rl.BLACK
    rulti.DEFAULT_TEXT_OPTIONS.size  = 12
    rulti.DEFAULT_TEXT_OPTIONS.center_x = false
    rulti.DEFAULT_TEXT_OPTIONS.center_y = false
    rulti.DEFAULT_TEXT_OPTIONS.highlight = {}
    rulti.DEFAULT_TEXT_OPTIONS.line_spacing = 0
    rl.SetTraceLogLevel(.INFO)

    window.camera.zoom = 1

    for !rl.WindowShouldClose() {
        defer handle_events()

        rl.BeginDrawing()
        defer rl.EndDrawing()
        rl.ClearBackground(rulti.gruvbox[.BG0_HARD])

        // on wayland, it reads primary clipboard before selection
        // so you must copy the files before dragging...
        // fuck glfw, fuck wayland, fuck computers. farming potatoes is da wae. 
        if rl.IsFileDropped() {
            dropped_files := rl.LoadDroppedFiles()
            for path in dropped_files.paths[:dropped_files.count] {
                file: File
				file.path = strings.clone(string(path))
                file.t    = rl.LoadTexture(path) when ODIN_OS != .Windows else load_tex_windows(string(path))
                file.pos  = { back(files).pos.x + back(files).size.x + 8, 0 }
                file.size = { f32(file.t.width), f32(file.t.height) }

                if rl.IsTextureValid(file.t) {
                    append(&files, file)
                } else { continue }

            }

            rl.UnloadDroppedFiles(dropped_files)
        }
    
        rl.BeginMode2D(window.camera) // steal camera from diagram tool?

        {
            text := "drag n' drop diagramas čia"
            opts := rulti.DEFAULT_TEXT_OPTIONS
            opts.color = rulti.gruvbox[.YELLOW1]
            opts.font  = mono_font
            opts.size  = 16
            rulti.DrawTextBasic(text, window.size/2 - rulti.MeasureTextLine(text, opts = opts)/2, opts)
        }

        for file, i in files {
            if rl.CheckCollisionPointRec(window.cursor, { file.pos.x, file.pos.y, file.size.x, file.size.y }) {
                rl.DrawRectangleV(file.pos - 4, file.size + 8, rulti.gruvbox[.ORANGE1])
                window.current_img = i
            }
            rl.DrawTextureV(file.t, file.pos, rl.WHITE)

            // cba to do more proper animations...
            if window.saving_anim > 0.01 && window.saved_index == i {
                idk := (file.size + 8) * { 0, window.saving_anim }
                rl.DrawRectangleV(file.pos - 4 + idk, file.size + 8 - idk, { 50, 170, 100, 50 })
                window.saving_anim *= 0.75
            }

            if window.saved_index == i {
                if window.save_state == .Render {
                    window.rt = rl.LoadRenderTexture(file.t.width, file.t.height)       
                    rl.BeginTextureMode(window.rt)
                    rl.DrawTextureV(file.t, {}, rl.WHITE)

                    for pnumber in numbers {
                        if !intersects(pnumber.pos, file.pos, file.size) do continue
                        rulti.DrawTextBasic(pnumber.number, pnumber.pos - file.pos)
                    }

                    rl.EndTextureMode()
                    window.save_state = .Save
                } else if window.save_state == .Save {

                    a := fp.dir(file.path, context.temp_allocator)
                    b := fmt.aprint("n", fp.base(file.path), sep="", allocator=context.temp_allocator)
                    c := fp.join({ a, b }, context.temp_allocator)
                    image := rl.LoadImageFromTexture(window.rt.texture) 
                    rl.ImageFlipVertical(&image)
					when ODIN_OS != .Windows {
						rl.ExportImage(image, strings.clone_to_cstring(c))
					} else {
						save_img_windows(image, c)
					}
					
					
                    window.save_state = .None
                }
            }
        }
        
        for pnumber in numbers {
            rulti.DrawTextBasic(pnumber.number, pnumber.pos)
        }

        {
            rulti.DEFAULT_TEXT_OPTIONS.font = font
            fmt_number := fmt.tprintf("%d:", number)

            text_size: Vector = rulti.MeasureTextLine(fmt_number)
            for r, i in fmt_number { 
                glyph_info := rl.GetGlyphInfo(font, r)
                glyph_img  := glyph_info.image
                
                text_size.x -= f32(glyph_info.offsetX)/4
                text_size.y  = min(text_size.y, f32(12 - glyph_info.offsetY/2) - 2)
            }
            text_size.x += 1

            pos := window.cursor - text_size
            rulti.DrawTextBasic(fmt_number, pos)

            if rl.IsMouseButtonPressed(.LEFT) { 
                append(&numbers, Numbering { strings.clone(fmt_number), pos }) 
                number += 1
                clear(&undoes)
            }

            for x : f32 = -30; x <= 30; x += 3 {
                p := window.cursor; p.x -= x
                rl.DrawLineV(p, p + { 2, 0 }, rl.BLACK)
            } 
            for y : f32 = -30; y <= 30; y += 3 {
                p := window.cursor; p.y -= y
                rl.DrawLineV(p, p + { 0, 2 }, rl.GRAY)
            } 
        }


        rl.EndMode2D()

        {
            rl.DrawTextureEx(mouse0_icon, { 7.5, 5 },  0, 0.75, rulti.gruvbox[.GREEN2])
            rl.DrawTextureEx(mouse1_icon, { 7.5, 23 }, 0, 0.75, rulti.gruvbox[.GREEN2])
            rl.DrawTextureEx(mouse2_icon, { 7.5, 40 }, 0, 0.75, rulti.gruvbox[.GREEN2])

            opts := rulti.DEFAULT_TEXT_OPTIONS
            opts.color = rulti.gruvbox[.GREEN2]
            opts.size  = 16
            opts.font  = mono_font
            rulti.DrawTextWrapped(HELP, { 10, 10 }, { 1000, 1000 }, opts)
        }

        if the_file != "" { rulti.DrawTextBasic(the_file, { 150, 10 }) }
        if the_file != "" do fmt.println(the_file)

        // { ~2000 FPS, fine I guess...
        //     opts := rulti.DEFAULT_TEXT_OPTIONS
        //     opts.color = rl.LIME
        //     opts.font  = mono_font
        //     opts.size  = 32
        //     rulti.DrawTextBasic(fmt.tprint(rl.GetFPS()), { 10, window.size.y - 42 }, opts)
        // }
        free_all(context.temp_allocator)
    }
}

// from my diagram editor
handle_events :: proc() {
    using window

    size  = { f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()) }
    mouse = rl.GetMousePosition()
    cursor = rl.GetScreenToWorld2D(mouse, camera)

    if rl.IsMouseButtonDown(.RIGHT) { 
        camera.target -= rl.GetMouseDelta() / camera.zoom
        camera_vel = { }
    }

    mouse1 := rl.GetScreenToWorld2D(mouse, camera)
    camera.zoom = math.exp_f32(math.log_f32(camera.zoom, math.E) + (cast (f32) rl.GetMouseWheelMove() * 0.2));
    mouse2 := rl.GetScreenToWorld2D(mouse, camera)
    camera.target += (mouse1 - mouse2) * math.sign(camera.zoom)


    key :: proc(k: rl.KeyboardKey) -> bool { return rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k)  }

    switch {
    case key(.MINUS): if number > 1 do  number -= 1 
    case key(.EQUAL):                   number += 1
    case key(.U)    : if len(numbers) > 0 { append(&undoes, pop(&numbers)); number -= 1 }                                                                  
    case key(.R)    : if len(undoes) > 0  { append(&numbers, pop(&undoes)); number += 1 }                                                      
    case key(.S)    : window.saved_index = window.current_img 
                      window.saving_anim = 1
                      window.save_state  = .Render
    }

}
