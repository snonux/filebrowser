//go:build !dev

package fbhttp

// global headers to append to every response
var globalHeaders = map[string]string{
	"Cache-Control": "no-cache, no-store, must-revalidate",

	// Forbid other sites from framing the interface, so a page cannot overlay
	// it and trick a logged-in user into clicking delete or share. The index
	// page is served by the router's NotFoundHandler, which skips the router
	// middleware and so carries no Content-Security-Policy; this header is set
	// on every response instead. Same-origin framing stays allowed because the
	// interface embeds its own previews.
	"X-Frame-Options": "SAMEORIGIN",
}
