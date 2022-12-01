import { MultiregionalPubNubManager } from "./MultiregionalPubNubManager";
const mpm = new MultiregionalPubNubManager({
    defaultConfig: {
        // The usual config with the primary origin
        publishKey: "demo",
        subscribeKey: "demo",
        userId: "myUniqueUserId",
        origin: "ringcentral.pubnubapi.com",
        suppressLeaveEvents: true,
        ssl: true,
    },
    backupOrigins: [
        "ringcentral-a.pubnubapi.com",
        "ringcentral-b.pubnubapi.com",
        "ringcentral-c.pubnubapi.com",
        "ringcentral-d.pubnubapi.com",
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
// await mpm.pubnub.publish({ channel: "some-channel", message: {"hello":"world"} });
// to trigger the failover manually:
// await mpm.failover();
