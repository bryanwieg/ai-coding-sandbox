//go:build tools

// Package tools pins gopls, which the image builds from this module.
package tools

import _ "golang.org/x/tools/gopls"
