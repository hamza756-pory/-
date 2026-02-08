/******/ (() => { // webpackBootstrap
/******/ 	"use strict";
/******/ 	var __webpack_modules__ = ({

/***/ "./src/prayer-times.ts"
/*!*****************************!*\
  !*** ./src/prayer-times.ts ***!
  \*****************************/
(__unused_webpack_module, __webpack_exports__, __webpack_require__) {

__webpack_require__.r(__webpack_exports__);
/* harmony export */ __webpack_require__.d(__webpack_exports__, {
/* harmony export */   formatTime: () => (/* binding */ formatTime),
/* harmony export */   getCurrentTimeInMinutes: () => (/* binding */ getCurrentTimeInMinutes),
/* harmony export */   getTimeRemaining: () => (/* binding */ getTimeRemaining),
/* harmony export */   getTimeRemainingInSeconds: () => (/* binding */ getTimeRemainingInSeconds),
/* harmony export */   prayerTimesData: () => (/* binding */ prayerTimesData),
/* harmony export */   qiblaAngles: () => (/* binding */ qiblaAngles),
/* harmony export */   timeToMinutes: () => (/* binding */ timeToMinutes),
/* harmony export */   toHijri: () => (/* binding */ toHijri)
/* harmony export */ });
const prayerTimesData = {
    cairo: {
        fajr: { adhan: "05:30", iqama: "05:45" },
        sunrise: "06:45",
        dhuhr: { adhan: "12:15", iqama: "12:30" },
        asr: { adhan: "15:30", iqama: "15:45" },
        maghrib: { adhan: "17:45", iqama: "17:46" },
        isha: { adhan: "19:15", iqama: "19:30" }
    },
    riyadh: {
        fajr: { adhan: "04:45", iqama: "05:00" },
        sunrise: "06:00",
        dhuhr: { adhan: "11:45", iqama: "12:00" },
        asr: { adhan: "14:30", iqama: "14:45" },
        maghrib: { adhan: "17:15", iqama: "17:16" },
        isha: { adhan: "18:45", iqama: "19:00" }
    },
    dubai: {
        fajr: { adhan: "05:00", iqama: "05:15" },
        sunrise: "06:15",
        dhuhr: { adhan: "12:00", iqama: "12:15" },
        asr: { adhan: "15:15", iqama: "15:30" },
        maghrib: { adhan: "17:30", iqama: "17:31" },
        isha: { adhan: "19:00", iqama: "19:15" }
    },
    beirut: {
        fajr: { adhan: "05:15", iqama: "05:30" },
        sunrise: "06:30",
        dhuhr: { adhan: "12:15", iqama: "12:30" },
        asr: { adhan: "15:30", iqama: "15:45" },
        maghrib: { adhan: "17:45", iqama: "17:46" },
        isha: { adhan: "19:15", iqama: "19:30" }
    },
    baghdad: {
        fajr: { adhan: "05:00", iqama: "05:15" },
        sunrise: "06:15",
        dhuhr: { adhan: "12:00", iqama: "12:15" },
        asr: { adhan: "15:15", iqama: "15:30" },
        maghrib: { adhan: "17:30", iqama: "17:31" },
        isha: { adhan: "19:00", iqama: "19:15" }
    },
    istanbul: {
        fajr: { adhan: "05:45", iqama: "06:00" },
        sunrise: "07:15",
        dhuhr: { adhan: "12:30", iqama: "12:45" },
        asr: { adhan: "15:45", iqama: "16:00" },
        maghrib: { adhan: "18:00", iqama: "18:01" },
        isha: { adhan: "19:30", iqama: "19:45" }
    },
    karachi: {
        fajr: { adhan: "05:20", iqama: "05:35" },
        sunrise: "06:35",
        dhuhr: { adhan: "12:10", iqama: "12:25" },
        asr: { adhan: "15:25", iqama: "15:40" },
        maghrib: { adhan: "17:40", iqama: "17:41" },
        isha: { adhan: "19:10", iqama: "19:25" }
    },
    lahore: {
        fajr: { adhan: "05:25", iqama: "05:40" },
        sunrise: "06:40",
        dhuhr: { adhan: "12:15", iqama: "12:30" },
        asr: { adhan: "15:30", iqama: "15:45" },
        maghrib: { adhan: "17:45", iqama: "17:46" },
        isha: { adhan: "19:15", iqama: "19:30" }
    },
    kuala_lumpur: {
        fajr: { adhan: "06:00", iqama: "06:15" },
        sunrise: "07:15",
        dhuhr: { adhan: "12:30", iqama: "12:45" },
        asr: { adhan: "15:45", iqama: "16:00" },
        maghrib: { adhan: "18:00", iqama: "18:01" },
        isha: { adhan: "19:30", iqama: "19:45" }
    },
    cape_town: {
        fajr: { adhan: "04:45", iqama: "05:00" },
        sunrise: "06:00",
        dhuhr: { adhan: "12:00", iqama: "12:15" },
        asr: { adhan: "15:15", iqama: "15:30" },
        maghrib: { adhan: "17:30", iqama: "17:31" },
        isha: { adhan: "19:00", iqama: "19:15" }
    }
};
const qiblaAngles = {
    cairo: 135,
    riyadh: 165,
    dubai: 145,
    beirut: 125,
    baghdad: 130,
    istanbul: 110,
    karachi: 95,
    lahore: 93,
    kuala_lumpur: 290,
    cape_town: 45
};
function timeToMinutes(timeStr) {
    const timeParts = timeStr.split(':');
    const hours = parseInt(timeParts[0] || '0');
    const minutes = parseInt(timeParts[1] || '0');
    return hours * 60 + minutes;
}
function getCurrentTimeInMinutes() {
    const now = new Date();
    return now.getHours() * 60 + now.getMinutes();
}
function getTimeRemaining(nextPrayerTime) {
    const currentTime = getCurrentTimeInMinutes();
    const prayerTime = timeToMinutes(nextPrayerTime);
    let diff = prayerTime - currentTime;
    if (diff < 0) {
        diff += 24 * 60;
    }
    const hours = Math.floor(diff / 60);
    const minutes = diff % 60;
    return `${hours}h ${minutes}m`;
}
function getTimeRemainingInSeconds(targetTime) {
    const now = new Date();
    const timeParts = targetTime.split(':');
    const targetHours = parseInt(timeParts[0] || '0');
    const targetMinutes = parseInt(timeParts[1] || '0');
    const targetDate = new Date(now);
    targetDate.setHours(targetHours, targetMinutes, 0, 0);
    if (targetDate <= now) {
        targetDate.setDate(targetDate.getDate() + 1);
    }
    const diffMs = targetDate.getTime() - now.getTime();
    return Math.floor(diffMs / 1000);
}
function formatTime(seconds) {
    const hrs = Math.floor(seconds / 3600);
    const mins = Math.floor((seconds % 3600) / 60);
    const secs = seconds % 60;
    return `${hrs.toString().padStart(2, '0')}:${mins.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
}
function toHijri(date) {
    const hijriYear = Math.floor((date.getFullYear() - 622) * 1.030688825);
    const monthNames = [
        'Muharram', 'Safar', 'Rabi\' al-Awwal', 'Rabi\' al-Thani',
        'Jumada al-Awwal', 'Jumada al-Thani', 'Rajab', 'Sha\'ban',
        'Ramadan', 'Shawwal', 'Dhu al-Qi\'dah', 'Dhu al-Hijjah'
    ];
    const hijriMonth = monthNames[date.getMonth()];
    const hijriDay = date.getDate();
    return `${hijriDay} ${hijriMonth} ${hijriYear} AH`;
}


/***/ }

/******/ 	});
/************************************************************************/
/******/ 	// The module cache
/******/ 	var __webpack_module_cache__ = {};
/******/ 	
/******/ 	// The require function
/******/ 	function __webpack_require__(moduleId) {
/******/ 		// Check if module is in cache
/******/ 		var cachedModule = __webpack_module_cache__[moduleId];
/******/ 		if (cachedModule !== undefined) {
/******/ 			return cachedModule.exports;
/******/ 		}
/******/ 		// Check if module exists (development only)
/******/ 		if (__webpack_modules__[moduleId] === undefined) {
/******/ 			var e = new Error("Cannot find module '" + moduleId + "'");
/******/ 			e.code = 'MODULE_NOT_FOUND';
/******/ 			throw e;
/******/ 		}
/******/ 		// Create a new module (and put it into the cache)
/******/ 		var module = __webpack_module_cache__[moduleId] = {
/******/ 			// no module.id needed
/******/ 			// no module.loaded needed
/******/ 			exports: {}
/******/ 		};
/******/ 	
/******/ 		// Execute the module function
/******/ 		__webpack_modules__[moduleId](module, module.exports, __webpack_require__);
/******/ 	
/******/ 		// Return the exports of the module
/******/ 		return module.exports;
/******/ 	}
/******/ 	
/************************************************************************/
/******/ 	/* webpack/runtime/define property getters */
/******/ 	(() => {
/******/ 		// define getter functions for harmony exports
/******/ 		__webpack_require__.d = (exports, definition) => {
/******/ 			for(var key in definition) {
/******/ 				if(__webpack_require__.o(definition, key) && !__webpack_require__.o(exports, key)) {
/******/ 					Object.defineProperty(exports, key, { enumerable: true, get: definition[key] });
/******/ 				}
/******/ 			}
/******/ 		};
/******/ 	})();
/******/ 	
/******/ 	/* webpack/runtime/hasOwnProperty shorthand */
/******/ 	(() => {
/******/ 		__webpack_require__.o = (obj, prop) => (Object.prototype.hasOwnProperty.call(obj, prop))
/******/ 	})();
/******/ 	
/******/ 	/* webpack/runtime/make namespace object */
/******/ 	(() => {
/******/ 		// define __esModule on exports
/******/ 		__webpack_require__.r = (exports) => {
/******/ 			if(typeof Symbol !== 'undefined' && Symbol.toStringTag) {
/******/ 				Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });
/******/ 			}
/******/ 			Object.defineProperty(exports, '__esModule', { value: true });
/******/ 		};
/******/ 	})();
/******/ 	
/************************************************************************/
var __webpack_exports__ = {};
// This entry needs to be wrapped in an IIFE because it needs to be isolated against other modules in the chunk.
(() => {
/*!*********************!*\
  !*** ./src/main.ts ***!
  \*********************/
__webpack_require__.r(__webpack_exports__);
/* harmony import */ var _prayer_times__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ./prayer-times */ "./src/prayer-times.ts");

class PrayerTimesApp {
    constructor() {
        this.countdownTimers = {};
        this.initializeEventListeners();
        this.refreshAll();
        setInterval(() => {
            this.refreshAll();
        }, 60000);
    }
    initializeEventListeners() {
        const citySelect = document.getElementById('city-select');
        citySelect.addEventListener('change', () => {
            this.refreshAll();
        });
        const refreshBtn = document.getElementById('refresh-btn');
        refreshBtn.addEventListener('click', () => {
            this.refreshAll();
        });
        const methodSelect = document.getElementById('method-select');
        methodSelect.addEventListener('change', () => {
            this.refreshAll();
        });
        const juristicSelect = document.getElementById('juristic-select');
        juristicSelect.addEventListener('change', () => {
            this.refreshAll();
        });
    }
    refreshAll() {
        this.updatePrayerTimes();
        this.updateDate();
        this.updateQiblaDirection();
        this.updateLastUpdateTime();
    }
    updatePrayerTimes() {
        const city = document.getElementById('city-select').value;
        const times = _prayer_times__WEBPACK_IMPORTED_MODULE_0__.prayerTimesData[city];
        if (!times) {
            console.error(`No prayer times found for city: ${city}`);
            return;
        }
        document.getElementById('fajr-time').textContent = times.fajr.adhan;
        document.getElementById('sunrise-time').textContent = times.sunrise;
        document.getElementById('dhuhr-time').textContent = times.dhuhr.adhan;
        document.getElementById('asr-time').textContent = times.asr.adhan;
        document.getElementById('maghrib-time').textContent = times.maghrib.adhan;
        document.getElementById('isha-time').textContent = times.isha.adhan;
        document.getElementById('fajr-iqama').textContent = `Iqama: ${times.fajr.iqama}`;
        document.getElementById('dhuhr-iqama').textContent = `Iqama: ${times.dhuhr.iqama}`;
        document.getElementById('asr-iqama').textContent = `Iqama: ${times.asr.iqama}`;
        document.getElementById('maghrib-iqama').textContent = `Iqama: ${times.maghrib.iqama}`;
        document.getElementById('isha-iqama').textContent = `Iqama: ${times.isha.iqama}`;
        Object.values(this.countdownTimers).forEach(timer => clearInterval(timer));
        this.countdownTimers = {};
        const currentTime = new Date();
        const currentHours = currentTime.getHours();
        const currentMinutes = currentTime.getMinutes();
        const currentTotalMinutes = currentHours * 60 + currentMinutes;
        const prayers = [
            { name: 'fajr', time: times.fajr.iqama },
            { name: 'dhuhr', time: times.dhuhr.iqama },
            { name: 'asr', time: times.asr.iqama },
            { name: 'maghrib', time: times.maghrib.iqama },
            { name: 'isha', time: times.isha.iqama }
        ];
        let nextPrayer = null;
        for (const prayer of prayers) {
            const timeParts = prayer.time.split(':');
            const hours = parseInt(timeParts[0] || '0');
            const minutes = parseInt(timeParts[1] || '0');
            const prayerTotalMinutes = hours * 60 + minutes;
            if (prayerTotalMinutes > currentTotalMinutes) {
                nextPrayer = prayer.name;
                break;
            }
        }
        if (!nextPrayer) {
            nextPrayer = 'fajr';
        }
        prayers.forEach(prayer => {
            const countdownElement = document.getElementById(`${prayer.name}-countdown`);
            if (!countdownElement)
                return;
            const remainingSeconds = (0,_prayer_times__WEBPACK_IMPORTED_MODULE_0__.getTimeRemainingInSeconds)(prayer.time);
            countdownElement.textContent = (0,_prayer_times__WEBPACK_IMPORTED_MODULE_0__.formatTime)(remainingSeconds);
            if (this.countdownTimers[prayer.name]) {
                clearInterval(this.countdownTimers[prayer.name]);
            }
            this.countdownTimers[prayer.name] = window.setInterval(() => {
                const remaining = (0,_prayer_times__WEBPACK_IMPORTED_MODULE_0__.getTimeRemainingInSeconds)(prayer.time);
                countdownElement.textContent = (0,_prayer_times__WEBPACK_IMPORTED_MODULE_0__.formatTime)(remaining);
                if (prayer.name === nextPrayer) {
                    countdownElement.style.color = '#ff6b6b';
                    countdownElement.style.fontWeight = 'bold';
                }
                else {
                    countdownElement.style.color = '#ccc';
                    countdownElement.style.fontWeight = 'normal';
                }
            }, 1000);
        });
    }
    updateDate() {
        const now = new Date();
        const gregorianOptions = {
            year: 'numeric',
            month: 'long',
            day: 'numeric',
            weekday: 'long'
        };
        const gregorianDate = now.toLocaleDateString('en-US', gregorianOptions);
        document.getElementById('gregorian-date').textContent = `Gregorian Date: ${gregorianDate}`;
        const hijriDate = (0,_prayer_times__WEBPACK_IMPORTED_MODULE_0__.toHijri)(now);
        document.getElementById('hijri-date').textContent = `Hijri Date: ${hijriDate}`;
    }
    updateQiblaDirection() {
        const city = document.getElementById('city-select').value;
        const angle = _prayer_times__WEBPACK_IMPORTED_MODULE_0__.qiblaAngles[city] || 0;
        const indicator = document.getElementById('qibla-indicator');
        if (indicator) {
            indicator.style.transform = `rotate(${angle}deg)`;
        }
    }
    updateLastUpdateTime() {
        const now = new Date();
        document.getElementById('last-update').textContent =
            now.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    }
}
document.addEventListener('DOMContentLoaded', () => {
    new PrayerTimesApp();
});

})();

/******/ })()
;
//# sourceMappingURL=bundle.js.map