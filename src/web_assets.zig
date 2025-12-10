//! Embedded web assets
//! These files are copied from web/dist/ to src/web_dist/ before build.
//! Run: cd web && bun run build && cp -r dist ../src/web_dist

pub const index_html = @embedFile("web_dist/index.html");
pub const app_js = @embedFile("web_dist/assets/app.js");
pub const index_css = @embedFile("web_dist/assets/index.css");
