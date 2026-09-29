// The shadow of a rounded box on the CPU (the XRender renderer's templates
// and the settings app's preview); the GL renderer evaluates the same
// formula in a shader.
package lactase

import "core:math"

// The shadow of a rounded box, as in the GL shader (Evan Wallace's formula).
shadow_value :: proc(lower, upper: [2]f32, point: [2]f32, sigma, corner: f32) -> f32 {
	gaussian :: proc(x, sigma: f32) -> f32 { return math.exp(-(x * x) / (2 * sigma * sigma)) / (2.5066282746 * sigma) }
	erf :: proc(x: f32) -> f32 {
		s: f32 = x < 0 ? -1 : 1
		a := abs(x)
		t := 1 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a
		t *= t
		return s - s / (t * t)
	}
	shadow_x :: proc(x, y, sigma, corner: f32, half: [2]f32) -> f32 {
		delta := min(half.y - corner - abs(y), 0)
		curved := half.x - corner + math.sqrt(max(0, corner * corner - delta * delta))
		k := 0.7071067811 / sigma
		lo := 0.5 + 0.5 * erf((x - curved) * k)
		hi := 0.5 + 0.5 * erf((x + curved) * k)
		return hi - lo
	}
	center := (lower + upper) * 0.5
	half := (upper - lower) * 0.5
	p := point - center
	low := p.y - half.y
	high := p.y + half.y
	start := clamp(-3 * sigma, low, high)
	end := clamp(3 * sigma, low, high)
	step := (end - start) / 4
	y := start + step * 0.5
	value: f32
	for _ in 0 ..< 4 {
		value += shadow_x(p.x, p.y - y, sigma, corner, half) * gaussian(y, sigma) * step
		y += step
	}
	return value
}

// A8 image of the shadow of a w×h box (plus e on every side).
shadow_image :: proc(w, h, e: i32, radius, sigma, opacity: f32) -> []u8 {
	iw, ih := w + 2 * e, h + 2 * e
	data := make([]u8, int(iw * ih), context.temp_allocator)
	lower := [2]f32{f32(e), f32(e)}
	upper := [2]f32{f32(e + w), f32(e + h)}
	rad := min(radius, f32(min(w, h)) / 2)
	for y in 0 ..< ih {
		for x in 0 ..< iw {
			v := shadow_value(lower, upper, {f32(x) + 0.5, f32(y) + 0.5}, sigma, rad) * opacity
			data[y * iw + x] = u8(clamp(v, 0, 1) * 255 + 0.5)
		}
	}
	return data
}

