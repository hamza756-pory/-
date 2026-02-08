from flask import Flask, render_template, jsonify
import json
import os
from datetime import datetime
import pytz

app = Flask(__name__)

# Prayer times data with Iqama times
PRAYER_TIMES_DATA = {
    "cairo": {
        "fajr": {"adhan": "05:30", "iqama": "05:45"},
        "sunrise": "06:45",
        "dhuhr": {"adhan": "12:15", "iqama": "12:30"},
        "asr": {"adhan": "15:30", "iqama": "15:45"},
        "maghrib": {"adhan": "17:45", "iqama": "17:46"},
        "isha": {"adhan": "19:15", "iqama": "19:30"}
    },
    "riyadh": {
        "fajr": {"adhan": "04:45", "iqama": "05:00"},
        "sunrise": "06:00",
        "dhuhr": {"adhan": "11:45", "iqama": "12:00"},
        "asr": {"adhan": "14:30", "iqama": "14:45"},
        "maghrib": {"adhan": "17:15", "iqama": "17:16"},
        "isha": {"adhan": "18:45", "iqama": "19:00"}
    },
    "dubai": {
        "fajr": {"adhan": "05:00", "iqama": "05:15"},
        "sunrise": "06:15",
        "dhuhr": {"adhan": "12:00", "iqama": "12:15"},
        "asr": {"adhan": "15:15", "iqama": "15:30"},
        "maghrib": {"adhan": "17:30", "iqama": "17:31"},
        "isha": {"adhan": "19:00", "iqama": "19:15"}
    },
    "beirut": {
        "fajr": {"adhan": "05:15", "iqama": "05:30"},
        "sunrise": "06:30",
        "dhuhr": {"adhan": "12:15", "iqama": "12:30"},
        "asr": {"adhan": "15:30", "iqama": "15:45"},
        "maghrib": {"adhan": "17:45", "iqama": "17:46"},
        "isha": {"adhan": "19:15", "iqama": "19:30"}
    },
    "baghdad": {
        "fajr": {"adhan": "05:00", "iqama": "05:15"},
        "sunrise": "06:15",
        "dhuhr": {"adhan": "12:00", "iqama": "12:15"},
        "asr": {"adhan": "15:15", "iqama": "15:30"},
        "maghrib": {"adhan": "17:30", "iqama": "17:31"},
        "isha": {"adhan": "19:00", "iqama": "19:15"}
    },
    "istanbul": {
        "fajr": {"adhan": "05:45", "iqama": "06:00"},
        "sunrise": "07:15",
        "dhuhr": {"adhan": "12:30", "iqama": "12:45"},
        "asr": {"adhan": "15:45", "iqama": "16:00"},
        "maghrib": {"adhan": "18:00", "iqama": "18:01"},
        "isha": {"adhan": "19:30", "iqama": "19:45"}
    },
    "karachi": {
        "fajr": {"adhan": "05:20", "iqama": "05:35"},
        "sunrise": "06:35",
        "dhuhr": {"adhan": "12:10", "iqama": "12:25"},
        "asr": {"adhan": "15:25", "iqama": "15:40"},
        "maghrib": {"adhan": "17:40", "iqama": "17:41"},
        "isha": {"adhan": "19:10", "iqama": "19:25"}
    },
    "lahore": {
        "fajr": {"adhan": "05:25", "iqama": "05:40"},
        "sunrise": "06:40",
        "dhuhr": {"adhan": "12:15", "iqama": "12:30"},
        "asr": {"adhan": "15:30", "iqama": "15:45"},
        "maghrib": {"adhan": "17:45", "iqama": "17:46"},
        "isha": {"adhan": "19:15", "iqama": "19:30"}
    },
    "kuala_lumpur": {
        "fajr": {"adhan": "06:00", "iqama": "06:15"},
        "sunrise": "07:15",
        "dhuhr": {"adhan": "12:30", "iqama": "12:45"},
        "asr": {"adhan": "15:45", "iqama": "16:00"},
        "maghrib": {"adhan": "18:00", "iqama": "18:01"},
        "isha": {"adhan": "19:30", "iqama": "19:45"}
    },
    "cape_town": {
        "fajr": {"adhan": "04:45", "iqama": "05:00"},
        "sunrise": "06:00",
        "dhuhr": {"adhan": "12:00", "iqama": "12:15"},
        "asr": {"adhan": "15:15", "iqama": "15:30"},
        "maghrib": {"adhan": "17:30", "iqama": "17:31"},
        "isha": {"adhan": "19:00", "iqama": "19:15"}
    }
}

# Qibla direction angles for different cities
QIBLA_ANGLES = {
    "cairo": 135,
    "riyadh": 165,
    "dubai": 145,
    "beirut": 125,
    "baghdad": 130,
    "istanbul": 110,
    "karachi": 95,
    "lahore": 93,
    "kuala_lumpur": 290,
    "cape_town": 45
}

def get_hijri_date():
    """Convert current Gregorian date to Hijri (simplified calculation)"""
    now = datetime.now()
    hijri_year = int((now.year - 622) * 1.030688825)
    month_names = [
        'Muharram', 'Safar', 'Rabi\' al-Awwal', 'Rabi\' al-Thani',
        'Jumada al-Awwal', 'Jumada al-Thani', 'Rajab', 'Sha\'ban',
        'Ramadan', 'Shawwal', 'Dhu al-Qi\'dah', 'Dhu al-Hijjah'
    ]
    hijri_month = month_names[now.month - 1]
    hijri_day = now.day
    
    return f"{hijri_day} {hijri_month} {hijri_year} AH"

@app.route('/')
def index():
    return app.send_static_file('index.html')

@app.route('/api/prayer-times/<city>')
def get_prayer_times(city):
    """API endpoint to get prayer times for a specific city"""
    if city not in PRAYER_TIMES_DATA:
        return jsonify({"error": "City not found"}), 404
    
    return jsonify({
        "city": city,
        "times": PRAYER_TIMES_DATA[city],
        "qibla_angle": QIBLA_ANGLES.get(city, 0),
        "hijri_date": get_hijri_date(),
        "gregorian_date": datetime.now().strftime("%A, %B %d, %Y")
    })

@app.route('/api/all-prayer-times')
def get_all_prayer_times():
    """API endpoint to get prayer times for all cities"""
    all_times = {}
    for city in PRAYER_TIMES_DATA:
        all_times[city] = {
            "times": PRAYER_TIMES_DATA[city],
            "qibla_angle": QIBLA_ANGLES.get(city, 0)
        }
    
    return jsonify({
        "data": all_times,
        "hijri_date": get_hijri_date(),
        "gregorian_date": datetime.now().strftime("%A, %B %d, %Y")
    })

@app.route('/api/update-prayer-times/<city>', methods=['POST'])
def update_prayer_times(city):
    """API endpoint to update prayer times for a specific city"""
    global PRAYER_TIMES_DATA
    
    if city not in PRAYER_TIMES_DATA:
        return jsonify({"error": "City not found"}), 404
    
    try:
        new_times = request.json.get("times")
        if not new_times:
            return jsonify({"error": "No times provided"}), 400
        
        # Validate the structure of new times
        required_keys = ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"]
        for key in required_keys:
            if key not in new_times:
                return jsonify({"error": f"Missing key: {key}"}), 400
        
        # Update the prayer times
        PRAYER_TIMES_DATA[city] = new_times
        return jsonify({
            "message": f"Prayer times updated for {city}",
            "updated_times": PRAYER_TIMES_DATA[city]
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000, debug=True)