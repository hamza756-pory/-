// بيانات المدن ومواقيت الصلاة
const prayerTimesData = {
    cairo: {
        fajr: "05:30",
        sunrise: "06:45",
        dhuhr: "12:15",
        asr: "15:30",
        maghrib: "17:45",
        isha: "19:15"
    },
    riyadh: {
        fajr: "04:45",
        sunrise: "06:00",
        dhuhr: "11:45",
        asr: "14:30",
        maghrib: "17:15",
        isha: "18:45"
    },
    dubai: {
        fajr: "05:00",
        sunrise: "06:15",
        dhuhr: "12:00",
        asr: "15:15",
        maghrib: "17:30",
        isha: "19:00"
    },
    beirut: {
        fajr: "05:15",
        sunrise: "06:30",
        dhuhr: "12:15",
        asr: "15:30",
        maghrib: "17:45",
        isha: "19:15"
    },
    baghdad: {
        fajr: "05:00",
        sunrise: "06:15",
        dhuhr: "12:00",
        asr: "15:15",
        maghrib: "17:30",
        isha: "19:00"
    }
};

// زوايا اتجاه القبلة حسب المدينة
const qiblaAngles = {
    cairo: 135,
    riyadh: 165,
    dubai: 145,
    beirut: 125,
    baghdad: 130
};

// دالة لتحويل الوقت إلى دقائق من منتصف الليل
function timeToMinutes(timeStr) {
    const [hours, minutes] = timeStr.split(':').map(Number);
    return hours * 60 + minutes;
}

// دالة للحصول على الوقت الحالي بالدقائق
function getCurrentTimeInMinutes() {
    const now = new Date();
    return now.getHours() * 60 + now.getMinutes();
}

// دالة لحساب الوقت المتبقي حتى الصلاة القادمة
function getTimeRemaining(nextPrayerTime) {
    const currentTime = getCurrentTimeInMinutes();
    const prayerTime = timeToMinutes(nextPrayerTime);
    
    // إذا كان وقت الصلاة قد فات اليوم، نحسب لليوم التالي
    let diff = prayerTime - currentTime;
    if (diff < 0) {
        diff += 24 * 60; // إضافة 24 ساعة بالدقائق
    }
    
    const hours = Math.floor(diff / 60);
    const minutes = diff % 60;
    
    return `${hours} س ${minutes} د`;
}

// دالة لتحديث عرض الأوقات والعد التنازلي
function updatePrayerTimes() {
    const city = document.getElementById('city-select').value;
    const times = prayerTimesData[city];
    
    // تحديث أوقات الصلاة
    document.getElementById('fajr-time').textContent = times.fajr;
    document.getElementById('sunrise-time').textContent = times.sunrise;
    document.getElementById('dhuhr-time').textContent = times.dhuhr;
    document.getElementById('asr-time').textContent = times.asr;
    document.getElementById('maghrib-time').textContent = times.maghrib;
    document.getElementById('isha-time').textContent = times.isha;
    
    // حساب الصلاة القادمة
    const currentTime = getCurrentTimeInMinutes();
    const prayers = ['fajr', 'sunrise', 'dhuhr', 'asr', 'maghrib', 'isha'];
    let nextPrayer = null;
    
    // البحث عن الصلاة القادمة
    for (let i = 0; i < prayers.length; i++) {
        if (prayers[i] === 'sunrise') continue; // تخطي الشروق من الحساب
        
        const prayerTime = timeToMinutes(times[prayers[i]]);
        if (prayerTime > currentTime) {
            nextPrayer = prayers[i];
            break;
        }
    }
    
    // إذا لم توجد صلاة قادمة اليوم، نأخذ أول صلاة غدًا
    if (!nextPrayer) {
        nextPrayer = 'fajr';
    }
    
    // تحديث العد التنازلي لأوقات الصلاة
    document.getElementById('fajr-countdown').textContent = getTimeRemaining(times.fajr);
    document.getElementById('dhuhr-countdown').textContent = getTimeRemaining(times.dhuhr);
    document.getElementById('asr-countdown').textContent = getTimeRemaining(times.asr);
    document.getElementById('maghrib-countdown').textContent = getTimeRemaining(times.maghrib);
    document.getElementById('isha-countdown').textContent = getTimeRemaining(times.isha);
    
    // تمييز الصلاة الحالية أو القادمة
    prayers.forEach(prayer => {
        if (prayer !== 'sunrise') {
            const element = document.getElementById(`${prayer}-countdown`);
            if (prayer === nextPrayer) {
                element.style.color = '#ff6b6b';
                element.style.fontWeight = 'bold';
            } else {
                element.style.color = '#ccc';
                element.style.fontWeight = 'normal';
            }
        }
    });
}

// دالة لتحديث التاريخ الهجري والميلادي
function updateDate() {
    const now = new Date();
    
    // التاريخ الميلادي
    const gregorianOptions = { year: 'numeric', month: 'long', day: 'numeric', weekday: 'long' };
    const gregorianDate = now.toLocaleDateString('ar-EG', gregorianOptions);
    document.getElementById('gregorian-date').textContent = `التاريخ الميلادي: ${gregorianDate}`;
    
    // التاريخ الهجري (حساب تقريبي)
    const hijriDate = toHijri(now);
    document.getElementById('current-date').textContent = `التاريخ الهجري: ${hijriDate}`;
}

// دالة لتحويل التاريخ الميلادي إلى هجري (حساب تقريبي)
function toHijri(date) {
    // هذا حساب مبسط للتاريخ الهجري
    const hijriYear = Math.floor((date.getFullYear() - 622) * 1.030688825);
    const monthNames = ['محرم', 'صفر', 'ربيع أول', 'ربيع ثاني', 'جمادى أول', 'جمادى ثاني', 'رجب', 'شعبان', 'رمضان', 'شوال', 'ذو القعدة', 'ذو الحجة'];
    const hijriMonth = monthNames[date.getMonth()];
    const hijriDay = date.getDate();
    
    return `${hijriDay} ${hijriMonth} ${hijriYear} هـ`;
}

// دالة لتحديث اتجاه القبلة
function updateQiblaDirection() {
    const city = document.getElementById('city-select').value;
    const angle = qiblaAngles[city] || 0;
    const indicator = document.getElementById('qibla-indicator');
    
    // تطبيق الزاوية على المؤشر
    indicator.style.transform = `rotate(${angle}deg)`;
}

// دالة لتحديث كل شيء
function refreshAll() {
    updatePrayerTimes();
    updateDate();
    updateQiblaDirection();
    
    // تحديث وقت آخر تحديث
    const now = new Date();
    document.getElementById('last-update').textContent = now.toLocaleTimeString('ar-SA');
}

// مستمع لتغيير المدينة
document.getElementById('city-select').addEventListener('change', function() {
    refreshAll();
});

// مستمع لزر التحديث
document.getElementById('refresh-btn').addEventListener('click', function() {
    refreshAll();
});

// مستمع لتغيير طريقة الحساب
document.getElementById('method-select').addEventListener('change', function() {
    // يمكن إضافة منطق حساب أوقات الصلاة حسب الطريقة المختارة
    refreshAll();
});

// مستمع لتغيير المذهب الفقهي
document.getElementById('juristic-select').addEventListener('change', function() {
    // يمكن إضافة منطق حساب صلاة العصر حسب المذهب
    refreshAll();
});

// تحديث كل 30 ثانية
setInterval(refreshAll, 30000);

// تهيئة الصفحة عند التحميل
document.addEventListener('DOMContentLoaded', function() {
    refreshAll();
});