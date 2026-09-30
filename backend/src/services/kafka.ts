import { Kafka, Producer, Consumer } from 'kafkajs';
import { query } from '../db/client';

const kafka = new Kafka({
  clientId: process.env.KAFKA_CLIENT_ID || 'lab-backend',
  brokers: (process.env.KAFKA_BROKERS || 'localhost:9092').split(','),
});

let producer: Producer;
let consumer: Consumer;

export const initKafka = async (): Promise<void> => {
  try {
    producer = kafka.producer();
    consumer = kafka.consumer({ groupId: 'backend-audit-group' });

    await producer.connect();
    await consumer.connect();

    await consumer.subscribe({ topics: ['lab.events', 'grade.events'], fromBeginning: true });

    await consumer.run({
      eachMessage: async ({ topic, partition, message }) => {
        if (!message.value) return;

        try {
          const event = JSON.parse(message.value.toString());
          const action = topic === 'lab.events' ? event.event || 'lab_event' : 'grade_event';
          const userId = event.userId || null;
          const resource = topic === 'lab.events' ? 'lab' : 'submission';
          const resourceId = topic === 'lab.events' ? event.labId : event.submissionId;

          await query(
            'INSERT INTO audit_log (user_id, action, resource, resource_id, created_at) VALUES ($1, $2, $3, $4, NOW())',
            [userId, action, resource, resourceId]
          );
        } catch (dbErr) {
          console.error('Error writing audit log to DB:', dbErr);
        }
      },
    });

    console.log('Kafka initialized successfully.');
  } catch (err) {
    console.error('Error initializing Kafka. Continuing without it.', err);
  }
};

export const emitLabEvent = async (labId: string, userId: string, event: string, meta?: object): Promise<void> => {
  if (!producer) return;
  try {
    await producer.send({
      topic: 'lab.events',
      messages: [{ value: JSON.stringify({ labId, userId, event, meta, timestamp: new Date().toISOString() }) }],
    });
  } catch (err) {
    console.error('Error emitting lab event:', err);
  }
};

export const emitGradeEvent = async (submissionId: string, labId: string, score: number, maxScore: number): Promise<void> => {
  if (!producer) return;
  try {
    await producer.send({
      topic: 'grade.events',
      messages: [{ value: JSON.stringify({ submissionId, labId, score, maxScore, timestamp: new Date().toISOString() }) }],
    });
  } catch (err) {
    console.error('Error emitting grade event:', err);
  }
};
