A three-member ZooKeeper 3.5.0 ensemble (one leader, two followers) is serving ordinary traffic.
A client connected to one of the followers calls the create overload that also returns the new
node's Stat — `create(path, data, acl, createMode, Stat)`; a plain `create(path, data, acl, createMode)`
on the very same connection had succeeded 8 ms earlier.
The call never completes: it fails with ConnectionLoss after the client's read timeout, and the
znode is never created anywhere in the ensemble.
From that moment on that follower answers nothing at all — every other client connected to it also
starts failing with ConnectionLoss, and their sessions are re-established with the same member only
to time out again — even though its process stays up, it keeps accepting connections, and the
leader and the other follower continue serving normally.
