// ──────────────────────────────────────────────────────────────
//   Structured stdout progress reporting
//   kyzu-game spawns kyzu-bake as a subprocess and parses these
// ──────────────────────────────────────────────────────────────

pub fn done(msg: &str)
{
  println!("[DONE] {}", msg);
}

pub fn wait(msg: &str)
{
  println!("[WAIT] {}", msg);
}

pub fn info(msg: &str)
{
  println!("[INFO] {}", msg);
}

pub fn error(msg: &str)
{
  eprintln!("[ERROR] {}", msg);
}

pub fn progress(percent: u32, msg: &str)
{
  println!("[PROGRESS] {} {}", percent.min(100), msg);
}
