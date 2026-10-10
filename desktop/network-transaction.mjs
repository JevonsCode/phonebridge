// One network change owns the configuration file and supervisor until it commits or fails.
export function serializeNetworkChange(change) {
  let pending = false;
  return async address => {
    if (pending) throw new Error('A network change is already in progress.');
    pending = true;
    try { return await change(address); } finally { pending = false; }
  };
}
