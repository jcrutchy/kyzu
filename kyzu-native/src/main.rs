mod app;
mod camera;
mod input;
mod renderer;

fn main()
{
  // Initialise the logger so wgpu validation errors and warnings appear in the console.
  // Set RUST_LOG=warn (default) or RUST_LOG=wgpu=debug for more verbose GPU output.

  std::env::set_var("RUST_LOG", "info,wgpu_hal=off,naga=warn");
  env_logger::init();

  app::run();
}
