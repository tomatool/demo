use std::{env, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let out = PathBuf::from(env::var("OUT_DIR")?);
    tonic_build::configure()
        .build_client(false)
        // Served over gRPC reflection, which tomato's grpc resource reads.
        .file_descriptor_set_path(out.join("catalog_descriptor.bin"))
        .compile_protos(&["../../proto/catalog/v1/catalog.proto"], &["../../proto"])?;
    Ok(())
}
