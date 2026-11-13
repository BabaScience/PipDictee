// Embeds the app icon and version information in PipDictee.exe. Only when building on Windows (CI, or a Windows
// PC): the resource compiler isn't available when type-checking from a Mac, and isn't needed there.
fn main() {
    println!("cargo:rerun-if-changed=assets/pip-dictee.ico");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") && cfg!(windows) {
        let mut res = winresource::WindowsResource::new();
        res.set_icon("assets/pip-dictee.ico")
            .set("ProductName", "Pip Dictée")
            .set("FileDescription", "Pip Dictée — local voice dictation")
            .set("LegalCopyright", "MIT License, Pip Dictée contributors");
        if let Err(e) = res.compile() { println!("cargo:warning=could not embed the icon: {e}"); }
    }
}
