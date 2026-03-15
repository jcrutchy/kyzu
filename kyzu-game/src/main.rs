mod app;
mod input;
mod renderer;

fn main()
{
  std::env::set_var("RUST_LOG", "info,wgpu_core=warn,wgpu_hal=warn,naga=warn");
  env_logger::init();
  app::run();
}
