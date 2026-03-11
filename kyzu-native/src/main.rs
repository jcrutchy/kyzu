mod app;
pub mod config;
pub mod earth;
mod input;
pub mod kzt;
mod renderer;
mod tiff_reader;

fn main()
{
  std::env::set_var("RUST_LOG", "info,wgpu_core=warn,wgpu_hal=warn,naga=warn");
  env_logger::init();
  app::run();
}
