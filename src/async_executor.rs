use gdnative::prelude::*;
use tokio::runtime::{Builder, Runtime};
use tokio::task::LocalSet;

#[derive(Default)]
pub(crate) struct SharedLocalPool {
    local_set: LocalSet,
}

thread_local! {
    pub(crate) static EXECUTOR: &'static SharedLocalPool = {
        Box::leak(Box::new(SharedLocalPool::default()))
    };
}

impl futures::task::LocalSpawn for SharedLocalPool {
    fn spawn_local_obj(
        &self,
        future: futures::task::LocalFutureObj<'static, ()>,
    ) -> Result<(), futures::task::SpawnError> {
        self.local_set.spawn_local(future);

        Ok(())
    }
}

#[derive(NativeClass)]
#[inherit(Node)]
pub(crate) struct AsyncExecutorDriver {
    runtime: Runtime,
}

#[methods]
impl AsyncExecutorDriver {
    fn new(_base: &Node) -> Self {
        AsyncExecutorDriver {
            runtime: Builder::new_current_thread()
                .enable_io() // optional, depending on your needs
                .enable_time() // optional, depending on your needs
                .build()
                .unwrap(),
        }
    }
    #[method]
    fn _process(&self, #[base] _base: &Node, _delta: f64) {
        EXECUTOR.with(|e| {
            self.runtime
                .block_on(async {
                    e.local_set
                        .run_until(async { tokio::task::spawn_local(async {}).await })
                        .await
                })
                .unwrap()
        })
    }
}
