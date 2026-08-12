A four-member ZooKeeper 3.5.0 ensemble (three participants and one observer) was rebuilt
during a maintenance window: the three participant machines were re-provisioned on empty
storage, and the observer machine was left as it was except that its transaction-log
directory now points at a replacement volume.

Since the restart the three participants form a healthy quorum and serve clients normally,
but the observer never rejoins it. Every attempt to join the leader ends in an unhandled
exception, after which the observer falls back to leader election and tries again — many
times a second, indefinitely, without ever making progress. Its process stays up, but it
reports that it is not currently serving requests and an ordinary client pointed at its
client port never gets a session. At the same time the number of sockets the observer
process holds open keeps growing, roughly one more per attempt, and they pile up in
CLOSE_WAIT.
