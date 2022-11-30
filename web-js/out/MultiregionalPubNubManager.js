import * as Pubnub from "pubnub";
const RECONNECTION_TIMEOUT = 60000;
const DIAGNOSIS_TIMEOUT = 10000;
const DIAGNOSIS_RETRIES = 5;
export class MultiregionalPubNubManager {
    get isInFailover() {
        return this.currentBackup !== null;
    }
    constructor(config) {
        this.config = config;
        this.handleStatus = (statusEvent) => {
            if (statusEvent.category === "PNNetworkIssuesCategory") {
                this.setupDiagnosis();
            }
        };
        this.managerListener = {
            status: this.handleStatus,
        };
        this.currentBackup = null;
        this.userListeners = [];
        this.subscriptions = [];
        this.unsubscriptions = [];
        this.setupDiagnosis = () => {
            this.diagnosisTimer = setTimeout(this.handleDiagnosis, DIAGNOSIS_TIMEOUT);
        };
        this.diagnosisRetries = 0;
        this.diagnosisTimer = null;
        this.handleDiagnosis = async () => {
            try {
                await this.tryOrigin(this.config.defaultConfig.origin, this.config.defaultConfig);
                clearTimeout(this.diagnosisTimer);
            }
            catch (e) {
                if (this.diagnosisRetries >= DIAGNOSIS_RETRIES - 1) {
                    this.diagnosisRetries = 0;
                    this.failover();
                }
                else {
                    this.diagnosisRetries += 1;
                    this.setupDiagnosis();
                }
            }
        };
        this.setupReconnection = () => {
            this.reconnectionTimer = setTimeout(this.handleReconnection, RECONNECTION_TIMEOUT);
        };
        this.reconnectionTimer = null;
        this.handleReconnection = async () => {
            try {
                await this.tryOrigin(this.config.defaultConfig.origin, this.config.defaultConfig);
                this.restore();
            }
            catch (e) {
                this.setupReconnection();
            }
        };
        this.tryOrigin = async (origin, config) => {
            const request = await fetch(`https://${origin}/v2/subscribe/${config.subscribeKey}/reconnection_test/0`);
            await request.json();
        };
        this.bindInstance(config.defaultConfig);
    }
    bindInstance(config) {
        this.instance = new Pubnub(config);
        this.instance.addListener(this.managerListener);
        for (const listener of this.userListeners) {
            this.instance.addListener(listener);
        }
        for (const subscription of this.subscriptions) {
            this.instance.subscribe(subscription);
        }
        for (const unsubscription of this.unsubscriptions) {
            this.instance.unsubscribe(unsubscription);
        }
    }
    unbindInstance() {
        if (this.instance) {
            // @ts-ignore
            this.instance.destroy();
            this.instance.removeListener(this.managerListener);
            for (const listener of this.userListeners) {
                this.instance.removeListener(listener);
            }
            this.instance = undefined;
        }
    }
    addListener(listener) {
        this.userListeners.push(listener);
        this.pubnub.addListener(listener);
    }
    removeListener(listener) {
        const index = this.userListeners.indexOf(listener);
        if (index >= 0) {
            this.userListeners.splice(index, 1);
        }
        this.pubnub.removeListener(listener);
    }
    subscribe(subscription) {
        this.subscriptions.push(subscription);
        this.pubnub.subscribe(subscription);
    }
    unsubscribe(unsubscription) {
        this.unsubscriptions.push(unsubscription);
        this.pubnub.unsubscribe(unsubscription);
    }
    get pubnub() {
        return this.instance;
    }
    async failover() {
        if (this.isInFailover) {
            this.currentBackup += 1;
        }
        else {
            this.currentBackup = 0;
            this.setupReconnection();
        }
        return this.bindFromBackup();
    }
    async bindFromBackup() {
        this.unbindInstance();
        const origin = this.config.backupOrigins[this.currentBackup];
        if (origin === undefined) {
            throw new Error("All backup origins are exhausted. Probably the internet is down?");
        }
        const config = { ...this.config.defaultConfig, origin: origin };
        try {
            await this.tryOrigin(origin, config);
            this.bindInstance(config);
        }
        catch (e) {
            console.log("Backup origin failed: ", origin);
            return this.failover();
        }
    }
    restore() {
        if (this.reconnectionTimer) {
            clearTimeout(this.reconnectionTimer);
        }
        this.unbindInstance();
        this.bindInstance(this.config.defaultConfig);
    }
}
