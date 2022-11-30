import { MultiregionalPubNubManager } from "./MultiregionalPubNubManager";
const mpm = new MultiregionalPubNubManager({
    defaultConfig: {
        // The usual config with the primary origin
        publishKey: "demo",
        subscribeKey: "demo",
        userId: "javascript-test",
        origin: "ps.pndsn.com",
        suppressLeaveEvents: true,
        ssl: true,
    },
    backupOrigins: [
        "ps1.pndsn.com",
        "ps2.pndsn.com",
        "ps3.pndsn.com",
        "ps4.pndsn.com",
        "ps5.pndsn.com",
    ],
});
// All subscribe-related functions must be called through the Manager
mpm.addListener({
    message(msg) {
        console.log("message", msg);
    },
});
mpm.subscribe({ channels: ["test", "test1"] });
mpm.unsubscribe({ channels: ["test"] });
// to use the rest of pubnub functions:
// await mpm.pubnub.objects.getChannelMembers({ channel: "some-channel" })
// to trigger the failover manually:
// await mpm.failover()
